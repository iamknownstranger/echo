import AVFoundation
import Foundation
import Testing
@testable import EchoMusic

@Test func sharedSongLinksRoundTrip() throws {
    let id = "a-bC_d12345"
    let song = Track(source: .youtube(id), title: "Song", artist: "Artist")
    for link in [try #require(song.shareURL).absoluteString, "https://youtu.be/\(id)?t=2",
                 "https://music.youtube.com/watch?v=\(id)", "echomusic://watch?v=\(id)"] {
        #expect(SongLink.videoID(try #require(URL(string: link))) == id)
    }
    for link in ["https://youtube.com.example/watch?v=\(id)", "https://youtube.com/other?v=\(id)",
                 "https://youtu.be/bad", "https://youtube.com/playlist?list=\(id)", "echomusic://listen?code=ABCDEFGH"] {
        #expect(SongLink.videoID(try #require(URL(string: link))) == nil)
    }
}

@Test func handlesSongRowsAndIgnoresMenuLinks() throws {
    let raw = """
    {"playlistItemData":{"videoId":"abcdefghijk"},"flexColumns":[
    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"First song"}]}}},
    {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"One","navigationEndpoint":{"browseEndpoint":{"browseId":"UCa"}}},{"text":" & "},{"text":"Two","navigationEndpoint":{"browseEndpoint":{"browseId":"UCb"}}},{"text":" • "},{"text":"Record","navigationEndpoint":{"browseEndpoint":{"browseId":"MPRE1"}}},{"text":" • "},{"text":"3:42"}]}}}],
    "menu":{"watchEndpoint":{"videoId":"other123456"}}}
    """
    let row = Node(value: try JSONSerialization.jsonObject(with: Data(raw.utf8)))
    let track = try #require(CatalogParser.song(row))
    #expect(track.artist == "One, Two")
    #expect(track.album == "Record")
    #expect(track.duration == 222)
    #expect(track.source == .youtube("abcdefghijk"))
    #expect(CatalogParser.song(row["menu"]) == nil)
}

@Test func timedLyricsRespectGapsAndRepeatedTimestamps() {
    let lines = Lyrics.parse("[ar:Artist]\n[00:04.5][01:20.123]Chorus\n[00:17.10]\n[00:62.0]Invalid")
    #expect(lines == [LyricLine(time: 4.5, text: "Chorus"), LyricLine(time: 17.1, text: ""), LyricLine(time: 80.123, text: "Chorus")])
}

@MainActor
@Test func libraryRoundTripAndCorruptFileRecovery() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("library.json")
    let source = Track(source: .youtube("abcdefghijk"), title: "Title", artist: "Artist")
    let library = Library(file: file)
    #expect(library.issue == nil)
    library.toggleLike(source)
    let id = try #require(library.newPlaylist("   Mix   "))
    library.add(source, to: id)
    library.add(source, to: id)
    let restored = Library(file: file)
    #expect(restored.track(forVideoID: "abcdefghijk") == source)
    #expect(restored.data.liked == [source])
    #expect(restored.data.playlists.first?.name == "Mix")
    #expect(restored.data.playlists.first?.tracks == [source])
    restored.toggleLike(source)
    restored.remove(source, from: id)
    #expect(Library(file: file).data.playlists.first?.tracks == [])
    let broken = Data("invalid".utf8)
    try broken.write(to: file)
    let unreadable = Library(file: file)
    #expect(unreadable.issue != nil)
    unreadable.toggleLike(source)
    #expect(try Data(contentsOf: file) == broken)
}

private func silentFile(at url: URL) throws {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88200))
    buffer.frameLength = buffer.frameCapacity
    buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength))
    try file.write(from: buffer)
}

@MainActor
private func waitFor(_ player: Player, seconds: TimeInterval = 8, until condition: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + seconds
    while !condition() {
        if let failure = player.failure { throw EchoError(failure) }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw EchoError("Player timed out at \(player.head.seconds) seconds.") }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

@MainActor
@Test func localPlaybackImportSeekAndQueue() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("Demo.caf")
    try silentFile(at: url)
    let file = directory.appendingPathComponent("library.json")
    let library = Library(file: file)
    let imported = await library.importFiles([url, url])
    let track = try #require(imported.first)
    #expect(track.title == "Demo")
    #expect(Library(file: file).data.files.count == 1)
    let player = Player(systemControls: false)
    player.volume = 0
    player.play([track, track])
    defer { player.pause() }
    try await waitFor(player) { player.head.seconds > 0.1 }
    player.pause()
    #expect(!player.wantsPlayback)
    player.seek(1.2)
    #expect(abs(player.head.seconds - 1.2) < 0.1)
    player.enqueue(track, next: true)
    player.removeUpcoming(2)
    #expect(player.queue.count == 2)
    player.resume()
    try await waitFor(player) { player.index == 1 && player.head.seconds > 0.1 }
    try await waitFor(player) { !player.wantsPlayback }
    player.resume()
    try await waitFor(player) { player.head.seconds > 0.1 && player.head.seconds < 1.5 }
    library.forgetFile(track)
    #expect(Library(file: file).data.files.isEmpty)
    #expect(FileManager.default.fileExists(atPath: url.path))
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ECHO_LIVE_TESTS"] == "1"))
func liveDiscoverySearchLyricsAndPlayback() async throws {
    let home = try await Catalog.shared.home()
    let collections = home.flatMap(\.entries).compactMap { entry -> MusicCollection? in
        if case .collection(let item) = entry { return item }; return nil
    }
    let collection = try #require(collections.first)
    let collectionPage = try await Catalog.shared.collection(collection.id)
    #expect(!collectionPage.tracks.isEmpty)

    let page = try await Catalog.shared.search("Daft Punk Harder Better Faster Stronger")
    let track = try #require(page.tracks.first)
    #expect(track.artist.contains("Daft Punk"))
    if let token = page.continuation {
        let more = try await Catalog.shared.search("Daft Punk Harder Better Faster Stronger", continuation: token)
        #expect(!more.tracks.isEmpty)
    }
    _ = try await Lyrics.fetch(track)
    let player = Player(systemControls: false)
    player.volume = 0
    player.play([track])
    defer { player.pause() }
    try await waitFor(player, seconds: 35) { player.head.seconds > 1 && !player.loading }
    #expect(player.duration > 60)
    player.seek(45)
    try await waitFor(player, seconds: 15) { player.head.seconds > 46 }
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ECHO_LIVE_TESTS"] == "1"))
func downloadAndReplayFromDisk() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("library.json")
    let library = Library(file: file)
    let page = try await Catalog.shared.search("Daft Punk Harder Better Faster Stronger")
    let track = try #require(page.tracks.first)
    await library.download(track)
    try #require(library.issue == nil, "\(library.issue ?? "")")
    let reopened = Library(file: file)
    let cached = try #require(reopened.offlineURL(track))
    #expect(cached.isFileURL)
    var usedCache = false
    let player = Player(systemControls: false) { track in
        usedCache = true
        return reopened.offlineURL(track)
    }
    player.volume = 0
    player.play([track])
    defer { player.pause() }
    try await waitFor(player) { player.head.seconds > 0.3 }
    #expect(usedCache)
    reopened.removeDownload(track)
    #expect(!FileManager.default.fileExists(atPath: cached.path))
    #expect(Library(file: file).data.downloads.isEmpty)
}

@MainActor
@Test func roomPlaybackLoadsWithoutStartingAndAppliesPausedSeek() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    try silentFile(at: url)
    let song = Track(source: .youtube("abcdefghijk"), title: "Room song", artist: "Artist")
    let upcoming = Track(source: .youtube("bcdefghijkl"), title: "Upcoming", artist: "Artist")
    let player = Player(systemControls: false, offlineURL: { _ in url })
    player.volume = 0
    player.setRoomQueue([song], at: 0, reload: true)
    try await waitFor(player) { player.roomReady }
    #expect(!player.wantsPlayback)
    #expect(player.roomPosition == 0)

    player.applyRoomPosition(1.25, playing: false)
    try await waitFor(player) { !player.roomSeekInProgress }
    #expect(abs(player.roomPosition - 1.25) < 0.05)
    #expect(!player.roomPlaying)

    let generation = player.roomTrackGeneration
    player.setRoomQueue([upcoming, song], at: 1)
    #expect(player.current == song)
    #expect(player.roomTrackGeneration == generation)
    #expect(abs(player.roomPosition - 1.25) < 0.05)

    player.applyRoomPosition(nil, playing: true)
    try await waitFor(player) { player.roomPlaying }
    player.pause()
}
