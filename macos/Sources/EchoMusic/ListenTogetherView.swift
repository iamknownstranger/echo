import AppKit
import SwiftUI

struct ListenTogetherView: View {
    @EnvironmentObject private var session: RoomSession
    @EnvironmentObject private var player: Player
    @Binding var inviteCode: String?
    @AppStorage("listenTogether.username") private var savedUsername = ""
    @ViewState private var savedServer = RoomSession.defaultServerURL
    @ViewState private var username = ""
    @ViewState private var codeInput = ""
    @AppStorage("listenTogether.customServerURL") private var customServer = ""
    @ViewState private var copiedItem: String?
    @ViewState private var serverOptions: [ListenServerOption] = [.init(name: "Metrolist Server", location: "Poland", url: RoomSession.defaultServerURL)]

    private var inRoom: Bool { session.state != nil }
    private var serverURL: String {
        let custom = customServer.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? savedServer : custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 23) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Listen Together").font(.system(size: 35, weight: .bold)).tracking(-1.4)
                    .accessibilityAddTraits(.isHeader)
            }
            if inRoom { roomPanel }
            else { setupPanel }
            if let message = session.errorMessage, !message.isEmpty {
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red).accessibilityLabel("Connection error: \(message)")
            }
            if let message = player.roomPlaybackIssue {
                Label(message, systemImage: "waveform.badge.exclamationmark")
                    .foregroundStyle(.orange).accessibilityLabel("Playback issue: \(message)")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 720, alignment: .leading)
        .onAppear {
            username = savedUsername
            if let inviteCode { codeInput = inviteCode; self.inviteCode = nil }
        }
        .onChange(of: inviteCode) { _, code in
            if let code { codeInput = code; inviteCode = nil }
        }
        .onChange(of: username) { _, value in savedUsername = value }
        .task { await loadAndroidServerChoice() }
        .onChange(of: inRoom) { _, _ in copiedItem = nil }
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 17) {
            Text("Start or join a room").font(.title2.bold())
            TextField("Your name", text: $username).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Your name")
            HStack(spacing: 10) {
                Text("Server").foregroundStyle(.secondary)
                Picker("Listen Together server", selection: $savedServer) {
                    ForEach(serverOptions) { server in
                        Text("\(server.name) · \(server.location)").tag(server.url)
                    }
                }.labelsHidden().frame(maxWidth: 300)
                TextField("Custom WebSocket URL (optional)", text: $customServer)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 285)
                    .accessibilityLabel("Custom server URL")
            }
            HStack(spacing: 12) {
                Button {
                    savedUsername = normalizedName
                    session.create(username: normalizedName, serverURL: serverURL)
                } label: { Label("Create room", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(normalizedName.isEmpty || operationActive)
                Divider().frame(height: 25)
                TextField("Room code or invite link", text: $codeInput)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Room code or invite link")
                Button("Join") {
                    guard let code = RoomInvite.code(from: codeInput) else { return }
                    savedUsername = normalizedName
                    session.join(code: code, username: normalizedName, serverURL: serverURL)
                }.buttonStyle(.bordered).disabled(normalizedName.isEmpty || RoomInvite.code(from: codeInput) == nil || operationActive)
            }
            Text("Room codes contain 8 letters or numbers. For an invite from Android, paste the shared link here.")
                .font(.caption).foregroundStyle(.secondary)
            if operationActive {
                HStack {
                    ProgressView().controlSize(.small)
                    if session.connection != .connected { Text(connectionLabel) }
                    else if session.joinPending { Text("Waiting for the host to approve your request…") }
                    else { Text("Creating your room…") }
                    Spacer()
                    Button("Cancel") { session.leave() }.buttonStyle(.bordered)
                }
            }
        }
        .padding(20).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var roomPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.role == .host ? "Your listening room" : "Joined listening room")
                        .font(.title2.bold())
                    Text(connectionLabel).font(.subheadline).foregroundStyle(connectionColor)
                        .accessibilityLabel("Connection status: \(connectionLabel)")
                }
                Spacer()
                Button("Leave room", role: .destructive) { session.leave() }
                    .buttonStyle(.bordered)
            }

            if let room = session.state {
                VStack(alignment: .leading, spacing: 10) {
                    Text("ROOM CODE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(room.roomCode).font(.system(size: 32, weight: .bold, design: .monospaced)).tracking(2)
                        .lineLimit(1).minimumScaleFactor(0.75)
                        .textSelection(.enabled).accessibilityLabel("Room code \(room.roomCode)")
                    HStack {
                        Button {
                            copy(room.roomCode, item: "code")
                        } label: {
                            Label(copiedItem == "code" ? "Code copied" : "Copy code", systemImage: "doc.on.doc")
                        }
                        if session.serverURL == RoomSession.defaultServerURL {
                            Button {
                                copy("https://metroserverx.meowery.eu/listen?code=\(room.roomCode)", item: "link")
                            } label: {
                                Label(copiedItem == "link" ? "Link copied" : "Copy invite link", systemImage: "link")
                            }
                        }
                    }.buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16).background(.background, in: RoundedRectangle(cornerRadius: 8))
                if session.serverURL != RoomSession.defaultServerURL {
                    Text("Choose the same server in Android’s Listen Together settings to use this code.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if session.role == .host {
                    Text("New members must be approved before they join.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !session.pendingJoins.isEmpty {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Join requests").font(.headline)
                            ForEach(session.pendingJoins) { request in
                                HStack {
                                    Image(systemName: "person.crop.circle")
                                    Text(request.username)
                                    Spacer()
                                    Button("Reject") { session.rejectJoin(userId: request.userId) }
                                    Button("Approve") { session.approveJoin(userId: request.userId) }
                                        .buttonStyle(.borderedProminent)
                                }.padding(.vertical, 3)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Listening now").font(.headline)
                        ForEach(room.users) { user in
                            HStack(spacing: 9) {
                                Image(systemName: user.isHost ? "crown.fill" : "person.fill")
                                    .foregroundStyle(user.isHost ? Color.echoAccent : .secondary)
                                Text(user.username)
                                if user.isHost { Text("HOST").font(.caption2.bold()).foregroundStyle(.secondary) }
                                Spacer()
                                Circle().fill(user.isConnected ? .green : .secondary).frame(width: 8, height: 8)
                                Text(user.isConnected ? "Connected" : "Reconnecting")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine)
                        }
                    }
                } else {
                    Text(session.canControlPlayback ? "Members can control playback." : "Playback follows the host.")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("Members").font(.headline)
                        ForEach(room.users) { user in
                            Label(user.username + (user.isHost ? " · Host" : ""), systemImage: user.isHost ? "crown" : "person")
                        }
                    }
                }
            }
        }.padding(20).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private func copy(_ text: String, item: String) {
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(text, forType: .string) { copiedItem = item }
    }

    private var normalizedName: String { username.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var connectionLabel: String {
        switch session.connection {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .error: "Connection error"
        case .disconnected: "Disconnected"
        }
    }
    private var connectionColor: Color {
        switch session.connection {
        case .connected: .green
        case .error: .red
        default: .secondary
        }
    }
    private var operationActive: Bool {
        switch session.connection {
        case .connecting, .reconnecting: true
        case .connected, .disconnected, .error: session.joinPending || session.creationPending || session.state != nil
        }
    }

    private func loadAndroidServerChoice() async {
        guard let url = URL(string: "https://raw.githubusercontent.com/EchoMusicApp/Echo-Music/refs/heads/main/app/server.json") else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let response = try JSONDecoder().decode(AndroidServerResponse.self, from: data)
            guard response.serverUrl.hasPrefix("wss://") || response.serverUrl.hasPrefix("ws://") else { return }
            let choice = ListenServerOption(name: response.name, location: response.region, url: response.serverUrl)
            await MainActor.run {
                serverOptions = [choice]
                savedServer = choice.url
            }
        } catch { /* Keep the Android-compatible fallback. */ }
    }
}

private struct ListenServerOption: Identifiable {
    let name: String
    let location: String
    let url: String
    var id: String { url }
}

private struct AndroidServerResponse: Decodable {
    let name: String
    let region: String
    let serverUrl: String
}

enum RoomInvite {
    static func code(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 512 else { return nil }
        if isRoomCode(value) { return value.uppercased() }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil, components.password == nil, components.port == nil else { return nil }

        let segments = components.path.split(separator: "/").map(String.init)
        let pathCode: String?
        if scheme == "https", host == "metroserverx.meowery.eu",
           segments.first == "listen", segments.count <= 2 {
            pathCode = segments.count == 2 ? segments[1] : nil
        } else if scheme == "echomusic", host == "listen", segments.isEmpty {
            pathCode = nil
        } else { return nil }

        let queryCodes = (components.queryItems ?? []).compactMap { item -> String? in
            guard item.name == "code" || item.name == "room" else { return nil }
            return item.value
        }
        guard queryCodes.count <= 1 else { return nil }
        return normalize(queryCodes.first ?? pathCode ?? "")
    }

    static func code(from url: URL) -> String? { code(from: url.absoluteString) }

    private static func normalize(_ value: String) -> String? {
        guard isRoomCode(value) else { return nil }
        return value.uppercased()
    }

    private static func isRoomCode(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 8 else { return false }
        return bytes.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }
    }
}
