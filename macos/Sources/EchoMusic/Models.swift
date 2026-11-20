import Foundation

enum Source: Codable, Hashable {
    case youtube(String)
    case file(URL)
}

struct Track: Identifiable, Codable, Hashable {
    let source: Source
    var title: String
    var artist: String
    var album: String?
    var artwork: URL?
    var duration: Double?

    var id: String {
        switch source {
        case .youtube(let id): return "youtube:\(id)"
        case .file(let url): return url.absoluteString
        }
    }

    var shareURL: URL? {
        guard case .youtube(let videoID) = source else { return nil }
        return URL(string: "https://share.echomusic.fun/watch?v=\(videoID)")
    }
}

struct MusicCollection: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let artwork: URL?
}

enum CatalogEntry: Identifiable {
    case track(Track)
    case collection(MusicCollection)

    var id: String {
        switch self {
        case .track(let track): return track.id
        case .collection(let collection): return collection.id
        }
    }
}

struct Shelf {
    let title: String
    let entries: [CatalogEntry]
}

struct TrackPage {
    var tracks: [Track]
    var continuation: String?
}

struct EchoError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum SongLink {
    static func videoID(_ url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              let host = parts.host?.lowercased() else { return nil }
        let path = parts.path.split(separator: "/").map(String.init)
        let id: String?
        switch (parts.scheme?.lowercased(), host) {
        case ("https", "youtu.be") where path.count == 1:
            id = path[0]
        case ("https", "share.echomusic.fun") where path.count == 1 && path[0] != "watch":
            id = path[0]
        case ("https", "youtube.com"), ("https", "www.youtube.com"), ("https", "m.youtube.com"),
             ("https", "music.youtube.com"), ("https", "share.echomusic.fun"):
            guard path == ["watch"] else { return nil }
            id = parts.queryItems?.first { $0.name == "v" }?.value
        case ("echomusic", "watch") where path.isEmpty:
            id = parts.queryItems?.first { $0.name == "v" }?.value
        default: return nil
        }
        return id.flatMap { validID($0) ? $0 : nil }
    }

    static func validID(_ id: String) -> Bool {
        id.utf8.count == 11 && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

func clockText(_ interval: Double) -> String {
    guard interval.isFinite, interval >= 0, interval < 1e9 else { return "–:––" }
    let seconds = Int(interval)
    if seconds >= 3600 {
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
