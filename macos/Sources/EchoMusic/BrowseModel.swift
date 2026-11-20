import SwiftUI

enum SectionID: Hashable {
    case discover, search, liked, files, downloads, listenTogether, playlist(UUID), collection(MusicCollection)
}

@MainActor
final class BrowseModel: ObservableObject {
    @Published var section = SectionID.discover
    @Published var query = ""
    @Published var submitted = ""
    @Published var listenTogetherInviteCode: String?
    @Published private(set) var shelves: [Shelf] = []
    @Published private(set) var discovering = false
    @Published private(set) var discoveryError: String?
    @Published private(set) var searchPage = TrackPage(tracks: [])
    @Published private(set) var searchBusy = false
    @Published private(set) var searchError: String?
    @Published private(set) var collectionPage = TrackPage(tracks: [])
    @Published private(set) var collectionBusy = false
    @Published private(set) var collectionError: String?
    private var searchTask: Task<Void, Never>?
    private var collectionTask: Task<Void, Never>?

    func discover() async {
        guard !discovering else { return }
        discovering = true
        discoveryError = nil
        defer { discovering = false }
        do { shelves = try await Catalog.shared.home() }
        catch { if !Task.isCancelled { discoveryError = error.localizedDescription } }
    }

    func search(more: Bool = false) {
        let text = more ? submitted : query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        section = .search
        searchTask?.cancel()
        let token = more ? searchPage.continuation : nil
        if !more { searchPage = TrackPage(tracks: []); submitted = text }
        searchBusy = true
        searchError = nil
        searchTask = Task {
            do {
                let page = try await Catalog.shared.search(text, continuation: token)
                try Task.checkCancellation()
                searchPage.tracks += page.tracks
                searchPage.continuation = page.continuation == token ? nil : page.continuation
            } catch { if !Task.isCancelled { searchError = error.localizedDescription } }
            if !Task.isCancelled { searchBusy = false }
        }
    }

    func show(_ collection: MusicCollection, more: Bool = false) {
        collectionTask?.cancel()
        section = .collection(collection)
        let token = more ? collectionPage.continuation : nil
        if !more { collectionPage = TrackPage(tracks: []) }
        collectionError = nil
        collectionBusy = true
        collectionTask = Task {
            do {
                let page = try await Catalog.shared.collection(collection.id, continuation: token)
                try Task.checkCancellation()
                collectionPage.tracks += page.tracks.map { track in
                    var track = track
                    if track.artwork == nil { track.artwork = collection.artwork }
                    return track
                }
                collectionPage.continuation = page.continuation == token ? nil : page.continuation
            } catch { if !Task.isCancelled { collectionError = error.localizedDescription } }
            if !Task.isCancelled { collectionBusy = false }
        }
    }
}
