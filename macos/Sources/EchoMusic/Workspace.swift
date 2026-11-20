import AppKit
import SwiftUI

// Select the property wrapper explicitly. Some Command Line Tools SDKs
// declare the newer State macro without shipping the SwiftUI macro plugin.
typealias ViewState<Value> = SwiftUI.State<Value>

extension Color {
    static let echoAccent = Color(red: 0.88, green: 0.22, blue: 0.23)
}

enum Inspector { case queue, lyrics }

struct Workspace: View {
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var browse: BrowseModel
    @FocusState private var searchFocused: Bool
    @ViewState private var inspector: Inspector?
    @ViewState private var playlistPrompt = false
    @ViewState private var playlistName = ""
    @ViewState private var playlistToDelete: Playlist?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 184)
                    .background(.thinMaterial)
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        if case .collection = browse.section {
                            Button { browse.section = .discover } label: { Image(systemName: "chevron.left") }
                                .buttonStyle(.plain).accessibilityLabel("Back to Discover")
                        }
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("Search songs or paste a song link", text: $browse.query)
                                .textFieldStyle(.plain).focused($searchFocused).onSubmit(submit)
                            if !browse.query.isEmpty {
                                Button { browse.query = ""; searchFocused = true } label: { Image(systemName: "xmark.circle.fill") }
                                    .buttonStyle(.plain).accessibilityLabel("Clear search")
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: 420)
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 26).padding(.vertical, 12)
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: 19) { page }
                            .padding(26).frame(maxWidth: .infinity, alignment: .leading)
                    }.id(browse.section)
                }
                if let inspector {
                    Divider()
                    InspectorView(mode: inspector, close: { self.inspector = nil })
                        .frame(width: 245)
                }
            }
            Divider()
            Transport(inspector: $inspector)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.echoAccent)
        .background {
            Button("Find a song") { browse.section = .search; searchFocused = true }
                .keyboardShortcut("f").hidden()
        }
        .task { if browse.shelves.isEmpty { await browse.discover() } }
        .alert("New playlist", isPresented: $playlistPrompt) {
            TextField("Playlist name", text: $playlistName)
            Button("Create") {
                if let id = library.newPlaylist(playlistName) { browse.section = .playlist(id) }
            }.disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete playlist?", isPresented: Binding(get: { playlistToDelete != nil }, set: { if !$0 { playlistToDelete = nil } })) {
            Button("Delete", role: .destructive) {
                if let list = playlistToDelete {
                    if browse.section == .playlist(list.id) { browse.section = .liked }
                    library.deletePlaylist(list.id)
                }
                playlistToDelete = nil
            }
            Button("Cancel", role: .cancel) { playlistToDelete = nil }
        } message: { Text(playlistToDelete?.name ?? "") }
        .alert("Echo Music", isPresented: Binding(get: { library.issue != nil }, set: { if !$0 { library.issue = nil } })) {
            Button("OK") { library.issue = nil }
        } message: { Text(library.issue ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 31, height: 31)
                Text("Echo Music").font(.system(size: 20, weight: .bold)).tracking(-0.7)
            }.padding(.vertical, 22).padding(.leading, 7)
            nav("Discover", "sparkle.magnifyingglass", .discover)
            nav("Search", "magnifyingglass", .search)
            nav("Listen Together", "person.2.wave.2", .listenTogether)
            Text("Library").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 21).padding(.horizontal, 10)
            nav("Liked songs", "heart", .liked)
            nav("Downloads", "arrow.down.circle", .downloads)
            nav("On this Mac", "internaldrive", .files)
            HStack {
                Text("Playlists").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { playlistName = ""; playlistPrompt = true } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain).accessibilityLabel("New playlist").help("New playlist")
            }.padding(.horizontal, 10).padding(.top, 21).padding(.bottom, 3)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(library.data.playlists) { list in
                        nav(list.name, "music.note.list", .playlist(list.id)).contextMenu {
                            Button("Delete playlist…") { playlistToDelete = list }
                        }
                    }
                }
            }
            Divider()
            Button { importAudio() } label: {
                Label(library.importsInProgress > 0 ? "Importing…" : "Import audio…", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
            }.buttonStyle(.plain).disabled(library.importsInProgress > 0)
        }.padding(.horizontal, 10).padding(.bottom, 8)
    }

    private func nav(_ name: String, _ symbol: String, _ destination: SectionID) -> some View {
        let selected = browse.section == destination
        return Button {
            browse.section = destination
            searchFocused = destination == .search
        } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).frame(width: 18)
                    .foregroundStyle(selected ? Color.echoAccent : .secondary)
                Text(name).fontWeight(selected ? .semibold : .regular).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(height: 33)
                .background(selected ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func importAudio() {
        guard let urls = AudioPicker.choose() else { return }
        Task { _ = await library.importFiles(urls); browse.section = .files }
    }

    private func submit() {
        let query = browse.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: query), url.scheme != nil, query.contains("://") {
            guard let id = SongLink.videoID(url) else { library.issue = "Paste an Echo or YouTube song link, or search by title or artist."; return }
            player.play([library.track(forVideoID: id)])
        } else { browse.search() }
        searchFocused = false
    }

    @ViewBuilder private var page: some View {
        switch browse.section {
        case .discover:
            heading("Discover")
            if browse.discovering { LoadingShelf() }
            if let error = browse.discoveryError {
                Notice(symbol: "network.slash", title: "Couldn’t load Discover", detail: error)
                Button("Try again") { Task { await browse.discover() } }
            }
            ForEach(Array(browse.shelves.enumerated()), id: \.offset) { _, shelf in
                shelfView(shelf)
            }
        case .search:
            heading("Search")
            if !browse.submitted.isEmpty {
                Text("Results for “\(browse.submitted)”").foregroundStyle(.secondary)
                TrackRows(tracks: browse.searchPage.tracks)
            }
            if browse.searchBusy { LoadingShelf() }
            else if let error = browse.searchError {
                Notice(symbol: "network.slash", title: "Search unavailable", detail: error)
                Button("Try again") { browse.search(more: browse.searchPage.continuation != nil) }
            } else if browse.searchPage.tracks.isEmpty {
                Notice(symbol: "magnifyingglass", title: browse.submitted.isEmpty ? "Find a song" : "No songs found",
                       detail: browse.submitted.isEmpty ? "Enter a title, artist, or Echo song link above." : "Try another title or artist.")
            } else if browse.searchPage.continuation != nil {
                Button("More results") { browse.search(more: true) }
            }
        case .listenTogether:
            ListenTogetherView(inviteCode: $browse.listenTogetherInviteCode)
        case .collection(let item):
            HStack(alignment: .bottom, spacing: 18) {
                Cover(url: item.artwork).frame(width: 94, height: 94)
                VStack(alignment: .leading, spacing: 6) {
                    heading(item.title)
                    Text(item.subtitle).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            TrackRows(tracks: browse.collectionPage.tracks)
            if browse.collectionBusy { LoadingShelf() }
            else if let error = browse.collectionError {
                Notice(symbol: "network.slash", title: "Collection unavailable", detail: error)
                Button("Try again") { browse.show(item, more: browse.collectionPage.continuation != nil) }
            } else if browse.collectionPage.continuation != nil {
                Button("More songs") { browse.show(item, more: true) }
            } else if browse.collectionPage.tracks.isEmpty { Notice(symbol: "music.note.list", title: "No songs available", detail: item.title) }
        case .liked:
            heading("Liked songs")
            if library.data.liked.isEmpty { Notice(symbol: "heart", title: "Save your favorites", detail: "Use the heart on any song to keep it here.") }
            TrackRows(tracks: library.data.liked)
        case .downloads:
            heading("Downloads")
            if !library.downloading.isEmpty { ProgressView("Downloading audio…").controlSize(.small) }
            if library.data.downloads.isEmpty && library.downloading.isEmpty {
                Notice(symbol: "arrow.down.circle", title: "Listen offline", detail: "Choose Download from a song’s menu to save it on this Mac.")
            }
            TrackRows(tracks: library.data.downloads)
        case .files:
            heading("On this Mac")
            if library.data.files.isEmpty {
                Notice(symbol: "waveform", title: "Play your own music", detail: "Import audio files from your Mac to listen offline.")
                Button("Import audio files…", action: importAudio)
            }
            TrackRows(tracks: library.data.files, localActions: true)
        case .playlist(let id):
            if let list = library.data.playlists.first(where: { $0.id == id }) {
                heading(list.name)
                if list.tracks.isEmpty {
                    Notice(symbol: "music.note.list", title: "Add the first song", detail: "Open a song’s menu and choose Add to playlist.")
                }
                TrackRows(tracks: list.tracks, playlist: id)
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.system(size: 35, weight: .bold)).tracking(-1.4).accessibilityAddTraits(.isHeader)
    }

    private func shelfView(_ shelf: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(shelf.title).font(.title2.bold()).tracking(-0.5).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(shelf.entries) { entry in
                        switch entry {
                        case .collection(let item):
                            Button { browse.show(item) } label: {
                                CoverCard(title: item.title, subtitle: item.subtitle, url: item.artwork)
                            }.buttonStyle(.plain)
                        case .track(let track):
                            Button {
                                let tracks = shelf.entries.compactMap { if case .track(let row) = $0 { return row }; return nil }
                                player.play(tracks, at: tracks.firstIndex(where: { $0.id == track.id }) ?? 0)
                            } label: { CoverCard(title: track.title, subtitle: track.artist, url: track.artwork) }
                            .buttonStyle(.plain).contextMenu { SongMenu(track: track) }
                        }
                    }
                }.padding(.bottom, 5)
            }
        }
    }
}
