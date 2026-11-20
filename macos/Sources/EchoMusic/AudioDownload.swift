import Foundation

enum AudioDownload {
    // Echo's playback service also requests media ranges. Only publish a file once
    // the server has returned every byte of the format selected by the catalog.
    static func write(_ source: URL, byteCount: Int64, to destination: URL) async throws {
        let fm = FileManager.default
        guard byteCount > 0, fm.createFile(atPath: destination.path, contents: nil) else {
            throw EchoError("Could not create the download file.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var offset: Int64 = 0
        while offset < byteCount {
            try Task.checkCancellation()
            let length = min(524_288, byteCount - offset)
            let end = offset + length - 1
            var request = URLRequest(url: source, timeoutInterval: 30)
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            let (chunk, response) = try await URLSession.shared.download(for: request)
            defer { try? fm.removeItem(at: chunk) }
            guard let http = response as? HTTPURLResponse,
                  let size = try chunk.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                throw EchoError("Could not verify the downloaded audio.")
            }
            let complete = offset == 0 && http.statusCode == 200 && Int64(size) == byteCount
            let partial = http.statusCode == 206 && Int64(size) == length &&
                http.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(end)/\(byteCount)"
            guard complete || partial else { throw EchoError("The download was incomplete. Try again.") }
            let input = try FileHandle(forReadingFrom: chunk)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 262_144), !data.isEmpty {
                try output.write(contentsOf: data)
            }
            offset += Int64(size)
        }
        guard try output.offset() == UInt64(byteCount) else { throw EchoError("The downloaded audio is incomplete.") }
    }
}
