import Foundation

struct LyricLine: Equatable {
    let time: Double
    let text: String
}

enum Lyrics {
    case synced([LyricLine])
    case plain(String)
    case instrumental

    static func parse(_ lrc: String) -> [LyricLine] {
        let time = /\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]/
        var lines: [LyricLine] = []
        for row in lrc.components(separatedBy: .newlines) {
            let stamps = row.matches(of: time)
            guard let last = stamps.last else { continue }
            let text = String(row[last.range.upperBound...]).trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                guard let minutes = Double(stamp.1), let seconds = Double(stamp.2), seconds < 60 else { continue }
                let fraction = stamp.3.flatMap { Double("0." + String($0)) } ?? 0
                lines.append(LyricLine(time: minutes * 60 + seconds + fraction, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    static func fetch(_ track: Track) async throws -> Lyrics {
        struct Match: Decodable {
            let duration: Double?
            let instrumental: Bool?
            let syncedLyrics: String?
            let plainLyrics: String?
            let trackName: String
            let artistName: String
        }
        guard !track.artist.isEmpty else { throw EchoError("Artist information is needed to find lyrics.") }
        var parts = URLComponents(string: "https://lrclib.net/api/search")!
        parts.queryItems = [URLQueryItem(name: "track_name", value: track.title), URLQueryItem(name: "artist_name", value: track.artist)]
        var req = URLRequest(url: parts.url!, timeoutInterval: 12)
        req.setValue("EchoMusic-macOS/0.1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EchoError("The lyrics service is unavailable.") }
        let matches = try JSONDecoder().decode([Match].self, from: data)
        func score(_ match: Match) -> Double {
            let delta = abs((match.duration ?? 0) - (track.duration ?? match.duration ?? 0))
            let namePenalty: Double = match.trackName.caseInsensitiveCompare(track.title) == .orderedSame ? 0 : 20
            let artistPenalty: Double = match.artistName.caseInsensitiveCompare(track.artist) == .orderedSame ? 0 : 10
            return delta + namePenalty + artistPenalty
        }
        for match in matches.sorted(by: { score($0) < score($1) }) {
            let durationMatches = track.duration.flatMap { expected in match.duration.map { abs(expected - $0) <= 5 } } ?? true
            if let lrc = match.syncedLyrics, durationMatches {
                let lines = parse(lrc)
                if !lines.isEmpty { return .synced(lines) }
            }
            if let plain = match.plainLyrics, !plain.isEmpty { return .plain(plain) }
            if match.instrumental == true { return .instrumental }
        }
        throw EchoError("No lyrics were found for this recording.")
    }
}
