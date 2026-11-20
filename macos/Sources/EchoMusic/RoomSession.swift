import Combine
import Foundation

struct RoomTrack: Codable, Equatable {
    var id: String
    var title: String
    var artist: String
    var album: String? = nil
    var duration: Int64
    var thumbnail: String? = nil
    var suggestedBy: String? = nil
    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, thumbnail
        case suggestedBy = "suggested_by"
    }
}
struct RoomUser: Codable, Equatable, Identifiable {
    var userId: String
    var username: String
    var isHost: Bool
    var isConnected: Bool = true
    var id: String { userId }
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case isHost = "is_host"
        case isConnected = "is_connected"
    }
}
struct RoomState: Codable, Equatable {
    var roomCode: String
    var hostId: String
    var users: [RoomUser]
    var currentTrack: RoomTrack? = nil
    var isPlaying: Bool
    var position: Int64
    var lastUpdate: Int64
    var volume: Float = 1
    var queue: [RoomTrack] = []
    var allowParticipantControl: Bool = false
    enum CodingKeys: String, CodingKey {
        case roomCode = "room_code"
        case hostId = "host_id"
        case users
        case currentTrack = "current_track"
        case isPlaying = "is_playing"
        case position
        case lastUpdate = "last_update"
        case volume, queue
        case allowParticipantControl = "allow_participant_control"
    }
}
struct RoomJoinRequest: Codable, Equatable, Identifiable {
    var userId: String
    var username: String
    var id: String { userId }
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
    }
}
struct RoomAction: Codable, Equatable {
    var action: String
    var trackId: String? = nil
    var position: Int64? = nil
    var trackInfo: RoomTrack? = nil
    var insertNext: Bool? = nil
    var queue: [RoomTrack]? = nil
    var queueTitle: String? = nil
    var volume: Float? = nil
    var serverTime: Int64? = nil
    var capturedAtServerTime: Int64? = nil
    var replaceQueue: Bool = false
    var originUserId: String? = nil
    enum CodingKeys: String, CodingKey {
        case action
        case trackId = "track_id"
        case position
        case trackInfo = "track_info"
        case insertNext = "insert_next"
        case queue
        case queueTitle = "queue_title"
        case volume
        case serverTime = "server_time"
        case capturedAtServerTime = "captured_at_server_time"
        case replaceQueue = "replace_queue"
        case originUserId = "origin_user_id"
    }
}
enum RoomRole { case none, host, guest }
enum RoomConnection { case disconnected, connecting, connected, reconnecting, error }
enum RoomPlaybackEvent {
    case action(RoomAction)
    case listenerJoined
    case state(RoomState)
    case bufferWait(String)
    case bufferComplete(String)
}

@MainActor final class RoomSession: ObservableObject {
    nonisolated static let defaultServerURL = "wss://metroserverx.meowery.eu/ws"
    @Published private(set) var state: RoomState?
    @Published private(set) var role: RoomRole = .none
    @Published private(set) var connection: RoomConnection = .disconnected
    @Published private(set) var userId: String?
    @Published private(set) var pendingJoins: [RoomJoinRequest] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var isAttached = false
    @Published private(set) var joinPending = false
    @Published private(set) var creationPending = false
    var onPlayback: ((RoomPlaybackEvent) -> Void)?
    var canControlPlayback: Bool { role == .host || (role == .guest && state?.allowParticipantControl == true) }
    private var socket: URLSessionWebSocketTask?
    private var sendTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private(set) var serverURL = defaultServerURL
    private var username = ""
    private var roomCode: String?
    private var token: String?
    private var pending: (String, [String: Any])?
    private var generation = 0
    private var protobuf = false
    private var sequence: UInt64 = 0
    private var probes: [UInt64: UInt64] = [:]
    private var clockSamples: [(rtt: UInt64, offset: Double)] = []
    private var recentActions: [(Date, RoomAction)] = []
    private var retries = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func create(username: String, serverURL: String = RoomSession.defaultServerURL) {
        start(username: username, serverURL: serverURL, command: ("create_room", ["username": username]))
        creationPending = connection != .error
    }
    func join(code: String, username: String, serverURL: String = RoomSession.defaultServerURL) {
        let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        start(
            username: username, serverURL: serverURL,
            command: ("join_room", ["room_code": normalized, "username": username]))
        joinPending = connection != .error
    }
    private func start(username: String, serverURL: String, command: (String, [String: Any])) {
        leave()
        self.username = username
        self.serverURL = serverURL
        pending = command
        connect()
    }
    func leave() {
        if socket != nil { send("leave_room") }
        generation += 1
        receiveTask?.cancel()
        pingTask?.cancel()
        reconnectTask?.cancel()
        let closingSocket = socket
        let finalSend = sendTask
        Task {
            await finalSend?.value
            closingSocket?.cancel(with: .normalClosure, reason: nil)
        }
        socket = nil
        sendTask = nil
        token = nil
        roomCode = nil
        pending = nil
        state = nil
        userId = nil
        role = .none
        pendingJoins = []
        recentActions.removeAll()
        isAttached = false
        joinPending = false
        creationPending = false
        connection = .disconnected
        errorMessage = nil
        retries = 0
    }
    private func finishWithError(_ message: String) {
        leave()
        connection = .error
        errorMessage = message
    }

    private func connect() {
        guard let url = URL(string: serverURL), ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
        else {
            errorMessage = "Invalid room server URL"
            connection = .error
            joinPending = false
            creationPending = false
            return
        }
        generation += 1
        let current = generation
        connection = retries == 0 ? .connecting : .reconnecting
        protobuf = false
        isAttached = false
        probes.removeAll()
        clockSamples.removeAll()
        recentActions.removeAll()
        sendTask = nil
        errorMessage = nil
        let ws = URLSession.shared.webSocketTask(with: url)
        socket = ws
        ws.resume()
        receiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let message = try await ws.receive()
                    guard let self, self.generation == current else { return }
                    switch message {
                    case .data(let data): self.handle(data)
                    case .string(let text): self.handle(Data(text.utf8))
                    @unknown default: break
                    }
                } catch {
                    guard let self, self.generation == current else { return }
                    self.disconnected(error)
                    return
                }
            }
        }
        pingTask = Task { [weak self] in
            guard let self else { return }
            self.ping()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard self.generation == current, !Task.isCancelled else { return }
            self.finishConnecting()
            while !Task.isCancelled && self.generation == current {
                self.ping()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }
    private func finishConnecting() {
        guard connection == .connecting || connection == .reconnecting else { return }
        connection = .connected
        if let pending {
            self.pending = nil
            send(pending.0, pending.1)
        } else if let token {
            send("reconnect", ["session_token": token])
        }
    }
    private func disconnected(_ error: Error) {
        pingTask?.cancel()
        socket = nil
        isAttached = false
        guard token != nil || pending != nil else {
            connection = .error
            joinPending = false
            creationPending = false
            errorMessage = error.localizedDescription
            return
        }
        retries += 1
        guard retries <= 15 else {
            connection = .error
            joinPending = false
            creationPending = false
            errorMessage = "Unable to reconnect to the room."
            return
        }
        connection = .reconnecting
        let delay = min(120.0, pow(2.0, Double(min(retries - 1, 7))))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }
    private func ping() {
        sequence += 1
        probes[sequence] = DispatchTime.now().uptimeNanoseconds
        if probes.count > 16 {
            probes.removeAll()
            probes[sequence] = DispatchTime.now().uptimeNanoseconds
        }
        send("ping", ["client_time": Int64(Date().timeIntervalSince1970 * 1000), "sequence": sequence])
    }
    func oneWayMillis() -> Int64? { clockSamples.min(by: { $0.rtt < $1.rtt }).map { Int64($0.rtt / 2_000_000) } }
    func serverNowMillis() -> Int64? {
        guard let sample = clockSamples.min(by: { $0.rtt < $1.rtt }) else { return nil }
        return Int64(exactly: (Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 + sample.offset).rounded(.down))
    }
    private func send(_ type: String, _ payload: [String: Any]? = nil) {
        guard let socket else { return }
        do {
            let data = try RoomWire.encode(type: type, payload: payload, protobuf: protobuf)
            let previous = sendTask
            let sendingGeneration = generation
            sendTask = Task { [weak self] in
                await previous?.value
                guard !Task.isCancelled else { return }
                do { try await socket.send(.data(data)) } catch {
                    guard let self, self.generation == sendingGeneration else { return }
                    self.errorMessage = error.localizedDescription
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }
    private func object<T: Encodable>(_ value: T) -> [String: Any]? {
        guard let data = try? encoder.encode(value) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) -> T? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
        return try? decoder.decode(type, from: data)
    }
    func approveJoin(userId: String) {
        guard role == .host else { return }
        send("approve_join", ["user_id": userId])
        pendingJoins.removeAll { $0.userId == userId }
    }
    func rejectJoin(userId: String) {
        guard role == .host else { return }
        send("reject_join", ["user_id": userId])
        pendingJoins.removeAll { $0.userId == userId }
    }
    func requestSync() { if state != nil { send("request_sync") } }
    func bufferReady(trackId: String) { send("buffer_ready", ["track_id": trackId]) }
    func sendPlayback(_ action: RoomAction) {
        guard canControlPlayback, isAttached else { return }
        var action = action
        if action.position != nil { action.capturedAtServerTime = serverNowMillis() }
        recentActions.append((Date(), action))
        recentActions = Array(recentActions.suffix(32))
        send("playback_action", object(action))
    }
    private func handle(_ data: Data) {
        do {
            let decoded = try RoomWire.decode(data)
            if decoded.protobuf { protobuf = true }
            let p = decoded.payload
            func string(_ key: String) -> String { p[key] as? String ?? "" }
            let probing = connection == .connecting || connection == .reconnecting
            let probeRejected =
                probing && decoded.type == "error"
                && ["invalid_message", "invalid_payload", "unknown_message", "unknown_message_type"].contains(string("code"))
            if probing && decoded.type == "error" && !probeRejected {
                let message = string("message")
                finishWithError(message)
                return
            }
            finishConnecting()
            if probeRejected { return }
            switch decoded.type {
            case "pong":
                if let seq = (p["sequence"] as? NSNumber)?.uint64Value, let sent = probes.removeValue(forKey: seq),
                    let recv = (p["server_receive_time"] as? NSNumber)?.doubleValue,
                    let send = (p["server_send_time"] as? NSNumber)?.doubleValue
                {
                    let now = DispatchTime.now().uptimeNanoseconds
                    let elapsed = now - sent
                    let processing = (send - recv) * 1_000_000
                    guard recv > 0, processing >= 0, processing <= Double(elapsed) + 1_000_000 else { return }
                    // The relay stamps whole milliseconds. A short exchange can round up by one.
                    let rtt = elapsed - UInt64(min(processing, Double(elapsed)))
                    clockSamples.append((rtt, (recv + send) / 2 - Double(sent + elapsed / 2) / 1_000_000))
                    clockSamples = Array(clockSamples.suffix(4))
                }
            case "room_created":
                let id = string("user_id")
                let code = string("room_code")
                guard !id.isEmpty, !code.isEmpty else { throw RoomWire.WireError.invalid }
                userId = id
                token = string("session_token")
                roomCode = code
                role = .host
                retries = 0
                creationPending = false
                state = RoomState(
                    roomCode: code, hostId: id,
                    users: [RoomUser(userId: id, username: username, isHost: true)], isPlaying: false, position: 0,
                    lastUpdate: Int64(Date().timeIntervalSince1970 * 1000))
                isAttached = true
                if let state { onPlayback?(.state(state)) }
            case "join_request":
                if let request = decode(RoomJoinRequest.self, p),
                    !pendingJoins.contains(where: { $0.userId == request.userId })
                {
                    pendingJoins.append(request)
                }
            case "join_approved", "reconnected":
                guard let raw = p["state"] as? [String: Any], var room = decode(RoomState.self, raw) else {
                    throw RoomWire.WireError.invalid
                }
                userId = string("user_id")
                roomCode = string("room_code")
                if decoded.type == "join_approved" { token = string("session_token") }
                role = decoded.type == "join_approved" ? .guest : ((p["is_host"] as? Bool ?? false) ? .host : .guest)
                // Field 10 is a revision on current Metroserver, not permission.
                // Only an explicit settings event can enable participant control.
                if decoded.protobuf { room.allowParticipantControl = false }
                state = room
                retries = 0
                isAttached = true
                joinPending = false
                onPlayback?(.state(room))
            case "join_rejected", "kicked":
                let reason = string("reason")
                let fallback = decoded.type == "kicked" ? "You were removed from the room." : "The host declined your request."
                finishWithError(reason.isEmpty ? fallback : reason)
            case "user_joined":
                let id = string("user_id")
                if !(state?.users.contains { $0.userId == id } ?? true) {
                    state?.users.append(RoomUser(userId: id, username: string("username"), isHost: false))
                }
                pendingJoins.removeAll { $0.userId == id }
                if role == .host { onPlayback?(.listenerJoined) }
            case "user_left": state?.users.removeAll { $0.userId == string("user_id") }
            case "user_disconnected", "user_reconnected":
                if let index = state?.users.firstIndex(where: { $0.userId == string("user_id") }) {
                    state?.users[index].isConnected = decoded.type == "user_reconnected"
                }
            case "host_changed":
                let id = string("new_host_id")
                state?.hostId = id
                if let count = state?.users.count {
                    for index in 0..<count { state?.users[index].isHost = state?.users[index].userId == id }
                }
                role = id == userId ? .host : .guest
            case "room_settings_changed":
                state?.allowParticipantControl = p["allow_participant_control"] as? Bool ?? false
            case "sync_playback":
                if var action = decode(RoomAction.self, p) {
                    if action.position == nil && action.serverTime != nil
                        && ["play", "pause", "seek"].contains(action.action)
                    {
                        action.position = 0
                    }
                    switch action.action {
                    case "play": state?.isPlaying = true
                    case "pause": state?.isPlaying = false
                    case "change_track": if let track = action.trackInfo { state?.currentTrack = track }
                    default: break
                    }
                    if let position = action.position { state?.position = position }
                    if let time = action.serverTime { state?.lastUpdate = time }
                    if let queue = action.queue, action.replaceQueue || action.action == "sync_queue" {
                        state?.queue = queue
                    }
                    recentActions.removeAll { Date().timeIntervalSince($0.0) > 3 }
                    if action.originUserId == userId { break }
                    if action.originUserId == nil,
                        let index = recentActions.firstIndex(where: {
                            $0.1.action == action.action
                                && ($0.1.trackId == nil || action.trackId == nil || $0.1.trackId == action.trackId)
                                && ($0.1.position ?? 0) == (action.position ?? 0) && $0.1.trackInfo == action.trackInfo
                                && ($0.1.queue ?? []) == (action.queue ?? [])
                                && $0.1.replaceQueue == action.replaceQueue
                                && ($0.1.insertNext ?? false) == (action.insertNext ?? false)
                        })
                    {
                        recentActions.remove(at: index)
                        break
                    }
                    onPlayback?(.action(action))
                }
            case "sync_state":
                if var room = state {
                    room.currentTrack = (p["current_track"] as? [String: Any]).flatMap { decode(RoomTrack.self, $0) }
                    room.isPlaying = p["is_playing"] as? Bool ?? false
                    room.position = (p["position"] as? NSNumber)?.int64Value ?? 0
                    room.lastUpdate = (p["last_update"] as? NSNumber)?.int64Value ?? 0
                    if let queue = p["queue"] as? [[String: Any]] {
                        room.queue = queue.compactMap { decode(RoomTrack.self, $0) }
                    }
                    state = room
                    onPlayback?(.state(room))
                }
            case "buffer_wait":
                onPlayback?(.bufferWait(string("track_id")))
            case "buffer_complete":
                onPlayback?(.bufferComplete(string("track_id")))
            case "error":
                if (creationPending || joinPending) && string("code") != "session_not_found" {
                    let message = string("message")
                    finishWithError(message)
                    return
                }
                if string("code") == "session_not_found", role == .guest, let roomCode {
                    token = nil
                    joinPending = true
                    send("join_room", ["room_code": roomCode, "username": username])
                } else {
                    if ["session_not_found", "room_not_found", "invalid_room_code", "invalid_payload"].contains(
                        string("code"))
                    {
                        finishWithError(string("message"))
                        return
                    }
                    creationPending = false
                    errorMessage = string("message")
                }
            default: break
            }
        } catch {
            let message = "Invalid room message: \(error.localizedDescription)"
            if isAttached { errorMessage = message } else { finishWithError(message) }
        }
    }
}
