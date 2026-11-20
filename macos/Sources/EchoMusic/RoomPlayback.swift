import Combine
import Foundation

extension Track {
    var roomTrackID: String? {
        guard case .youtube(let id) = source, SongLink.validID(id) else { return nil }
        return id
    }
}

struct RoomPlayheadAnchor {
    let position: Int64
    let playing: Bool
    let receivedAt: UInt64
    let transit: Int64

    init(position: Int64, playing: Bool, receivedAt: UInt64, serverTime: Int64?,
         serverNow: Int64?, oneWay: Int64, snapshot: Bool) {
        self.position = max(0, position)
        self.playing = playing
        self.receivedAt = receivedAt
        if let serverNow, let serverTime, serverTime > 0, serverNow >= serverTime,
           serverNow - serverTime <= (snapshot ? 86_400_000 : 3_000) {
            transit = serverNow - serverTime
        } else {
            transit = min(max(0, oneWay), 1_500)
        }
    }

    func seconds(at time: UInt64, duration: Double) -> Double {
        let elapsed = playing && time >= receivedAt ? Double(time - receivedAt) / 1e9 : 0
        let position = Double(position) / 1000 + (playing ? Double(transit) / 1000 : 0) + elapsed
        return duration.isFinite && duration > 0 ? min(position, duration) : position
    }
}

struct BufferedRoomPlayback {
    let trackID: String
    var anchor: RoomPlayheadAnchor
    private(set) var waitingForRoom: Bool
    private var shouldReportReady: Bool

    init(trackID: String, anchor: RoomPlayheadAnchor, needsBarrier: Bool) {
        self.trackID = trackID
        self.anchor = anchor
        waitingForRoom = needsBarrier
        shouldReportReady = needsBarrier
    }

    mutating func complete(trackID: String) {
        if trackID == self.trackID { waitingForRoom = false }
    }

    mutating func localReady(trackID: String?) -> Bool {
        guard self.trackID == trackID, shouldReportReady else { return false }
        shouldReportReady = false
        return true
    }
}

/// An unmarked snapshot may contain the full queue or only upcoming entries.
func incomingRoomQueueIndex(_ ids: [String], activeID: String, currentIDs: [String],
                            currentIndex: Int?, upcoming: Bool) -> Int? {
    guard !upcoming else { return nil }
    var occurrence = 0
    if let currentIndex, currentIDs.indices.contains(currentIndex), currentIDs[currentIndex] == activeID {
        if currentIDs.suffix(from: currentIndex + 1).elementsEqual(ids) { return nil }
        occurrence = currentIDs.prefix(currentIndex).filter { $0 == activeID }.count
    }
    let matches = ids.indices.filter { ids[$0] == activeID }
    return occurrence < matches.count ? matches[occurrence] : matches.first
}

private func roomMilliseconds(_ seconds: Double) -> Int64 {
    guard seconds.isFinite, seconds > 0 else { return 0 }
    return Int64(min((seconds * 1000).rounded(), Double(Int64.max).nextDown))
}

@MainActor
final class RoomPlayback {
    private weak var player: Player?
    private weak var session: RoomSession?
    private var subscriptions: Set<AnyCancellable> = []
    private var heartbeat: Task<Void, Never>?
    private var rateReset: Task<Void, Never>?
    private var pending: BufferedRoomPlayback?
    private var latest: RoomPlayheadAnchor?
    private var latestServerTime: Int64?
    private var publishedGeneration: UUID?
    private var publishedPlaying: Bool?
    private var locallyDriven = false
    private var awaitingRemotePlayback = false

    var expectsRemoteTrackChanges: Bool { session?.role == .guest }
    var expectsSharedTracks: Bool { (session?.role ?? .none) != .none }

    init(player: Player, session: RoomSession) {
        self.player = player
        self.session = session
        session.onPlayback = { [weak self] event in self?.receive(event) }
        session.$role.removeDuplicates().sink { [weak self] role in
            let wasHost = self?.session?.role == .host
            self?.reset()
            if role == .none {
                self?.player?.roomPlaybackIssue = nil
            } else {
                Task { @MainActor [weak self] in
                    guard let self, self.session?.role == role else { return }
                    if role == .host { self.publishHostState() }
                    else if wasHost { self.session?.requestSync() }
                }
            }
        }.store(in: &subscriptions)
        session.$connection.removeDuplicates().sink { [weak self] connection in
            if connection != .connected { self?.reset() }
        }.store(in: &subscriptions)
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if self.session?.role == .host, self.pending == nil, let player = self.player,
                   player.roomPlaying && !player.roomSeekInProgress {
                    self.sendPosition("play")
                }
            }
        }
    }

    deinit {
        heartbeat?.cancel()
        rateReset?.cancel()
    }

    private var canPublish: Bool {
        guard let session else { return false }
        return session.isAttached && session.canControlPlayback
    }

    func allowsLocalControl(track: Track?) -> Bool {
        guard let session, session.role != .none else { return true }
        guard session.canControlPlayback else { return false }
        if let track, track.roomTrackID == nil {
            player?.roomPlaybackIssue = "Choose a YouTube Music track to play in this room."
            return false
        }
        return true
    }

    private func reset() {
        pending = nil
        latest = nil
        latestServerTime = nil
        publishedGeneration = nil
        publishedPlaying = nil
        locallyDriven = false
        awaitingRemotePlayback = false
        stopRateCorrection()
        player?.disconnectRoomPlayback()
    }

    private func publishHostState() {
        guard canPublish, let session, session.role == .host, let player,
              player.roomTrackGeneration != publishedGeneration else { return }
        guard let current = player.current, let trackID = current.roomTrackID else {
            if let state = session.state, state.currentTrack != nil {
                applySnapshot(state, at: DispatchTime.now().uptimeNanoseconds)
            } else if player.current != nil {
                player.pause()
                player.roomPlaybackIssue = "Only YouTube Music tracks can be shared in the room."
            }
            return
        }
        if session.state?.currentTrack?.id == trackID {
            publishedGeneration = player.roomTrackGeneration
            locallyDriven = true
            localQueueChanged()
        } else {
            localTrackChanged()
        }
        sendPosition(player.roomPlaying ? "play" : "pause")
        publishedPlaying = player.roomPlaying
    }

    func localTrackChanged() {
        guard canPublish, let player, let track = player.current?.asRoomTrack else { return }
        pending = nil
        latest = nil
        latestServerTime = nil
        stopRateCorrection()
        locallyDriven = true
        awaitingRemotePlayback = false
        player.roomPlaybackIssue = nil
        session?.sendPlayback(RoomAction(action: "change_track", trackInfo: track,
                                        queue: upcomingTracks, replaceQueue: true))
        publishedGeneration = player.roomTrackGeneration
        publishedPlaying = false
    }

    func localQueueChanged() {
        guard canPublish, let player, player.current?.roomTrackID != nil else { return }
        session?.sendPlayback(RoomAction(action: "sync_queue", queue: upcomingTracks, replaceQueue: true))
    }

    func localPlayStateChanged() {
        guard canPublish else { return }
        pending = nil
        latest = nil
        locallyDriven = true
        awaitingRemotePlayback = false
        stopRateCorrection()
        playerStatusChanged()
    }

    func localSeeked(to seconds: Double) {
        guard canPublish, let player else { return }
        pending = nil
        latest = nil
        locallyDriven = true
        awaitingRemotePlayback = false
        stopRateCorrection()
        if player.roomTrackGeneration != publishedGeneration { localTrackChanged() }
        sendPosition("seek", seconds: seconds)
    }

    func playerStatusChanged() {
        if pending != nil {
            finishBuffering()
            return
        }
        guard canPublish, let player, player.roomTrackGeneration == publishedGeneration, !player.roomSeekInProgress,
              locallyDriven || session?.role == .host else { return }
        let playing = player.roomPlaying
        if awaitingRemotePlayback {
            if playing { awaitingRemotePlayback = false }
            return
        }
        if playing != publishedPlaying {
            sendPosition(playing ? "play" : "pause")
            publishedPlaying = playing
        }
    }

    private var upcomingTracks: [RoomTrack] {
        guard let player, let index = player.index else { return [] }
        return player.queue.dropFirst(index + 1).compactMap(\.asRoomTrack)
    }

    private func sendPosition(_ action: String, seconds: Double? = nil) {
        guard canPublish, let player, let trackId = player.current?.roomTrackID else { return }
        session?.sendPlayback(RoomAction(action: action, trackId: trackId,
                                        position: roomMilliseconds(seconds ?? player.roomPosition)))
    }

    private func receive(_ event: RoomPlaybackEvent) {
        guard let session, session.isAttached else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        switch event {
        case .state(let state):
            if session.role == .host {
                publishHostState()
            } else if session.role == .guest {
                applySnapshot(state, at: now)
            }
        case .listenerJoined:
            // Android also accepts full queues from older relays. Identify the upcoming
            // occurrences explicitly when it receives a fresh, unmarked room snapshot.
            localQueueChanged()
        case .action(let action):
            apply(action, at: now)
        case .bufferWait:
            break
        case .bufferComplete(let trackID):
            pending?.complete(trackID: trackID)
            finishBuffering()
        }
    }

    private func applySnapshot(_ state: RoomState, at time: UInt64) {
        guard acceptsTimestamp(state.lastUpdate) else { return }
        let anchor = makeAnchor(state.position, state.isPlaying, time, state.lastUpdate, snapshot: true)
        // Metroserver stores upcoming occurrences separately from the active track.
        apply(track: state.currentTrack, queue: state.queue, anchor: anchor, needsBarrier: false, upcoming: true)
    }

    private func acceptsTimestamp(_ timestamp: Int64?) -> Bool {
        guard let timestamp, timestamp > 0 else { return true }
        if let latestServerTime, timestamp < latestServerTime { return false }
        latestServerTime = timestamp
        return true
    }

    private func makeAnchor(_ position: Int64, _ playing: Bool, _ time: UInt64, _ serverTime: Int64?,
                            snapshot: Bool = false) -> RoomPlayheadAnchor {
        RoomPlayheadAnchor(position: position, playing: playing, receivedAt: time, serverTime: serverTime,
                           serverNow: session?.serverNowMillis(), oneWay: session?.oneWayMillis() ?? 0,
                           snapshot: snapshot)
    }

    private func apply(_ action: RoomAction, at now: UInt64) {
        guard let player else { return }
        switch action.action {
        case "play", "pause", "seek":
            guard let trackID = player.current?.roomTrackID,
                  action.trackId == nil || action.trackId == trackID,
                  action.action != "seek" || action.position != nil,
                  acceptsTimestamp(action.serverTime) else { return }
            let previous = pending?.anchor ?? latest
            let playing = action.action == "seek" ? previous?.playing ?? player.wantsPlayback : action.action == "play"
            let position = action.position ?? roomMilliseconds(previous?.seconds(at: now, duration: player.duration)
                                                              ?? player.roomPosition)
            let anchor = action.position == nil
                ? RoomPlayheadAnchor(position: position, playing: playing, receivedAt: now,
                                     serverTime: nil, serverNow: nil, oneWay: 0, snapshot: false)
                : makeAnchor(position, playing, now, action.serverTime)
            locallyDriven = false
            latest = anchor
            if pending != nil {
                pending?.anchor = anchor
                finishBuffering()
            } else if player.roomReady {
                align(anchor, force: action.action != "play")
            } else {
                pending = BufferedRoomPlayback(trackID: trackID, anchor: anchor, needsBarrier: false)
            }
        case "change_track":
            guard let track = action.trackInfo, acceptsTimestamp(action.serverTime) else { return }
            apply(track: track, queue: action.queue,
                  anchor: makeAnchor(0, false, now, nil), needsBarrier: true, upcoming: action.replaceQueue)
        case "sync_queue":
            guard let tracks = action.queue else { return }
            replaceQueue(tracks.compactMap(\.asTrack), current: player.current, upcoming: action.replaceQueue)
        case "queue_add":
            guard let track = action.trackInfo?.asTrack else { return }
            var queue = player.queue
            let insertion = action.insertNext == true ? player.index.map { $0 + 1 } ?? 0 : queue.count
            queue.insert(track, at: insertion)
            player.setRoomQueue(queue, at: player.index)
        case "queue_remove":
            guard let trackID = action.trackId, let index = player.index,
                  let offset = player.queue.indices.dropFirst(index + 1).first(where: {
                      player.queue[$0].roomTrackID == trackID
                  }) else { return }
            var queue = player.queue
            queue.remove(at: offset)
            player.setRoomQueue(queue, at: index)
        case "queue_clear":
            let keep = player.index.map { $0 + 1 } ?? 0
            player.setRoomQueue(Array(player.queue.prefix(keep)), at: player.index)
        case "skip_next", "skip_prev":
            guard let index = player.index else { return }
            let offset = index + (action.action == "skip_next" ? 1 : -1)
            guard player.queue.indices.contains(offset),
                  let trackID = player.queue[offset].roomTrackID else { return }
            let anchor = makeAnchor(0, player.wantsPlayback, now, nil)
            pending = BufferedRoomPlayback(trackID: trackID, anchor: anchor, needsBarrier: false)
            latest = anchor
            locallyDriven = false
            stopRateCorrection()
            player.setRoomQueue(player.queue, at: offset, reload: true)
            publishedGeneration = player.roomTrackGeneration
        default:
            break
        }
    }

    private func apply(track: RoomTrack?, queue: [RoomTrack]?, anchor: RoomPlayheadAnchor,
                       needsBarrier: Bool, upcoming: Bool = false) {
        guard let player else { return }
        pending = nil
        latest = anchor
        locallyDriven = false
        stopRateCorrection()
        guard let track, let current = track.asTrack else {
            let remaining = queue?.compactMap(\.asTrack) ?? []
            player.setRoomQueue(remaining, at: nil)
            player.roomPlaybackIssue = track == nil ? nil : "The current room track is unavailable on this Mac."
            return
        }
        player.roomPlaybackIssue = nil
        pending = BufferedRoomPlayback(trackID: track.id, anchor: anchor, needsBarrier: needsBarrier)
        let sameTrack = current.roomTrackID == player.current?.roomTrackID
        if !sameTrack || queue != nil {
            replaceQueue(queue?.compactMap(\.asTrack) ?? [], current: current, upcoming: upcoming,
                         reload: !sameTrack || player.failure != nil)
        }
        publishedGeneration = player.roomTrackGeneration
        if needsBarrier || !player.roomReady { player.applyRoomPosition(nil, playing: false) }
        finishBuffering()
    }

    private func replaceQueue(_ new: [Track], current: Track?, upcoming: Bool, reload: Bool = false) {
        guard let player else { return }
        guard let current, let currentID = current.roomTrackID else {
            player.setRoomQueue(new, at: nil)
            return
        }
        let index = incomingRoomQueueIndex(new.map { $0.roomTrackID ?? "" }, activeID: currentID,
                                           currentIDs: player.queue.map { $0.roomTrackID ?? "" },
                                           currentIndex: player.index, upcoming: upcoming)
        player.setRoomQueue(index == nil ? [current] + new : new, at: index ?? 0, reload: reload)
    }

    private func finishBuffering() {
        guard let player, player.roomReady, var update = pending,
              update.trackID == player.current?.roomTrackID else { return }
        let report = update.localReady(trackID: player.current?.roomTrackID)
        pending = update.waitingForRoom ? update : nil
        if report { session?.bufferReady(trackId: update.trackID) }
        if !update.waitingForRoom { align(update.anchor, force: true) }
    }

    private func align(_ anchor: RoomPlayheadAnchor, force: Bool) {
        guard let player else { return }
        stopRateCorrection()
        let target = anchor.seconds(at: DispatchTime.now().uptimeNanoseconds, duration: player.duration)
        let error = target - player.roomPosition
        let tolerance = min(0.08, 0.012 + Double(session?.oneWayMillis() ?? 0) / 2000)
        let canAdjust = !force && anchor.playing && player.roomPlaying && !player.roomSeekInProgress
        publishedPlaying = anchor.playing
        awaitingRemotePlayback = anchor.playing && !player.roomPlaying
        if abs(error) > (force || !canAdjust ? 0.001 : tolerance) {
            if canAdjust && abs(error) < 0.180 {
                let multiplier = 1 + min(max(error / 2, -0.025), 0.025)
                player.setRoomRate(Float(multiplier))
                rateReset = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { self?.stopRateCorrection() }
                }
                return
            }
            player.applyRoomPosition(target, playing: anchor.playing)
        } else {
            player.applyRoomPosition(nil, playing: anchor.playing)
        }
    }

    private func stopRateCorrection() {
        guard let rateReset else { return }
        rateReset.cancel()
        self.rateReset = nil
        player?.setRoomRate(1)
    }
}

private extension Track {
    var asRoomTrack: RoomTrack? {
        guard let id = roomTrackID else { return nil }
        return RoomTrack(id: id, title: title, artist: artist, album: album,
                         duration: duration.flatMap { $0 > 0 ? roomMilliseconds($0) : nil } ?? 180_000,
                         thumbnail: artwork?.absoluteString)
    }
}

private extension RoomTrack {
    var asTrack: Track? {
        guard SongLink.validID(id) else { return nil }
        return Track(source: .youtube(id), title: title, artist: artist, album: album,
                     artwork: thumbnail.flatMap { URL(string: $0) },
                     duration: duration > 0 ? Double(duration) / 1000 : nil)
    }
}
