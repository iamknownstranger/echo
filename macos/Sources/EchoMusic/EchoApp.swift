import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct EchoApp: App {
    @StateObject private var library: Library
    @StateObject private var player: Player
    @StateObject private var roomSession: RoomSession
    @StateObject private var browse = BrowseModel()

    init() {
        let store = Library()
        let room = RoomSession()
        let playback = Player(offlineURL: { store.offlineURL($0) })
        playback.attachRoom(room)
        _library = StateObject(wrappedValue: store)
        _roomSession = StateObject(wrappedValue: room)
        _player = StateObject(wrappedValue: playback)
    }

    var body: some Scene {
        Window("Echo Music", id: "player") {
            Workspace()
                .environmentObject(library).environmentObject(player).environmentObject(browse)
                .environmentObject(roomSession)
                .frame(minWidth: 790, minHeight: 540)
                .onOpenURL { url in
                    if url.isFileURL { importFiles([url], play: true) }
                    else { playLink(url) }
                }
        }
        .defaultSize(width: 1160, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Audio Files…") {
                    if let urls = AudioPicker.choose() { importFiles(urls, play: false) }
                }.keyboardShortcut("o")
            }
            CommandMenu("Playback") {
                Button(player.wantsPlayback ? "Pause" : "Play") { player.toggle() }
                    .keyboardShortcut("p", modifiers: [.command]).disabled(player.current == nil || (roomSession.role == .guest && !roomSession.canControlPlayback))
                Button("Previous Song") { player.previous() }.keyboardShortcut(.leftArrow, modifiers: .command).disabled(player.current == nil || (roomSession.role == .guest && !roomSession.canControlPlayback))
                Button("Next Song") { player.next() }.keyboardShortcut(.rightArrow, modifiers: .command).disabled(!player.hasNext || (roomSession.role == .guest && !roomSession.canControlPlayback))
            }
        }
    }

    private func importFiles(_ urls: [URL], play: Bool) {
        Task {
            let tracks = await library.importFiles(urls)
            browse.section = .files
            if play, !tracks.isEmpty { player.play(tracks) }
        }
    }

    private func playLink(_ url: URL) {
        if let code = RoomInvite.code(from: url) {
            browse.section = .listenTogether
            browse.listenTogetherInviteCode = code
            return
        }
        guard let id = SongLink.videoID(url) else { library.issue = "Open an Echo or YouTube Music song link."; return }
        player.play([library.track(forVideoID: id)])
    }
}

enum AudioPicker {
    @MainActor static func choose() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
