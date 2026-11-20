import AppKit
import SwiftUI

struct Cover: View {
    let url: URL?
    var body: some View {
        ZStack {
            Color.primary.opacity(0.065)
            Image(systemName: "waveform").foregroundStyle(.secondary).accessibilityHidden(true)
            if let url {
                AsyncImage(url: url) { image in image.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}

struct CoverCard: View {
    let title: String
    let subtitle: String
    let url: URL?

    // The catalog also serves these thumbnails at row size. Request artwork
    // large enough for the desktop shelf on a Retina display.
    private var coverURL: URL? {
        guard let url, url.host?.hasSuffix(".googleusercontent.com") == true,
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let range = parts.percentEncodedPath.range(of: "=w[0-9]+-h[0-9]+", options: .regularExpression) else { return url }
        parts.percentEncodedPath.replaceSubrange(range, with: "=w500-h500")
        return parts.url ?? url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Cover(url: coverURL).frame(width: 162, height: 162).padding(.bottom, 3)
            Text(title).font(.headline).lineLimit(1)
            if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
        }.frame(width: 162, alignment: .leading).contentShape(Rectangle())
    }
}

struct LoadingShelf: View {
    var body: some View {
        HStack(spacing: 12) {
            ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 7).fill(.quaternary).frame(maxWidth: 162).frame(height: 90) }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Loading music")
    }
}

struct Notice: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: symbol).font(.title).foregroundStyle(.secondary).padding(.bottom, 5)
            Text(title).font(.title3.bold())
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 14)
    }
}

struct SongMenu: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library
    let track: Track
    var playlist: UUID?
    var localActions = false

    var body: some View {
        Button("Play next") { player.enqueue(track, next: true) }
        Button("Add to queue") { player.enqueue(track) }
        Button(library.likes(track) ? "Remove from liked songs" : "Like song") { library.toggleLike(track) }
        Menu("Add to playlist") {
            ForEach(library.data.playlists) { list in
                Button(list.name) { library.add(track, to: list.id) }.disabled(list.tracks.contains { $0.id == track.id })
            }
        }.disabled(library.data.playlists.isEmpty)
        if let playlist { Button("Remove from playlist") { library.remove(track, from: playlist) } }
        if let url = track.shareURL {
            Divider()
            if library.offlineURL(track) != nil {
                Button("Remove download") { library.removeDownload(track) }
            } else {
                Button(library.downloading.contains(track.id) ? "Downloading…" : "Download") {
                    Task { await library.download(track) }
                }.disabled(library.downloading.contains(track.id))
            }
            Button("Copy Echo song link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        }
        if localActions, case .file(let url) = track.source {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Remove from library") { library.forgetFile(track) }
        }
    }
}

struct TrackRows: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library
    let tracks: [Track]
    var playlist: UUID?
    var localActions = false

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { index, track in
                HStack(spacing: 10) {
                    Button { player.play(tracks, at: index) } label: {
                        HStack(spacing: 10) {
                            Cover(url: track.artwork).frame(width: 37, height: 37)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(track.title).fontWeight(.medium).lineLimit(1)
                                    .foregroundStyle(player.current?.id == track.id ? Color.echoAccent : .primary)
                                Text(track.artist.isEmpty ? "Unknown artist" : track.artist)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Play \(track.title), \(track.artist)")
                    if let duration = track.duration { Text(clockText(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Button { library.toggleLike(track) } label: { Image(systemName: library.likes(track) ? "heart.fill" : "heart") }
                        .buttonStyle(.borderless).accessibilityLabel(library.likes(track) ? "Unlike \(track.title)" : "Like \(track.title)")
                    Menu {
                        SongMenu(track: track, playlist: playlist, localActions: localActions)
                    } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Options for \(track.title)")
                }.padding(.vertical, 7)
                .contextMenu { SongMenu(track: track, playlist: playlist, localActions: localActions) }
                Divider()
            }
        }
    }
}

struct Transport: View {
    @EnvironmentObject private var player: Player
    @EnvironmentObject private var library: Library
    @EnvironmentObject private var room: RoomSession
    @Binding var inspector: Inspector?

    var body: some View {
        VStack(spacing: 5) {
            if let failure = player.failure {
                HStack {
                    Image(systemName: "exclamationmark.circle")
                    Text(failure).lineLimit(2)
                    Spacer()
                    Button("Retry") { player.resume() }
                }.font(.callout).padding(.bottom, 4)
            }
            HStack(spacing: 12) {
                Cover(url: player.current?.artwork).frame(width: 45, height: 45)
                VStack(alignment: .leading, spacing: 3) {
                    Text(player.current?.title ?? "Nothing playing").lineLimit(1).font(.headline)
                    if let track = player.current {
                        Text(player.loading ? "Loading audio…" : track.artist).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(minWidth: 70, idealWidth: 155, maxWidth: 190, alignment: .leading)
                if let track = player.current {
                    Button { library.toggleLike(track) } label: { Image(systemName: library.likes(track) ? "heart.fill" : "heart") }
                        .buttonStyle(.plain).accessibilityLabel("Toggle liked song")
                }
                Spacer(minLength: 3)
                Group {
                    Button { player.previous() } label: { Image(systemName: "backward.fill") }
                        .accessibilityLabel("Previous song").disabled(player.current == nil)
                    Button { player.toggle() } label: {
                        Image(systemName: player.wantsPlayback ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 33))
                    }.accessibilityLabel(player.wantsPlayback ? "Pause" : "Play").disabled(player.current == nil)
                    Button { player.next() } label: { Image(systemName: "forward.fill") }
                        .accessibilityLabel("Next song").disabled(!player.hasNext)
                    Scrubber(head: player.head).frame(minWidth: 80, maxWidth: .infinity).padding(.horizontal, 5)
                }.disabled(room.role == .guest && !room.canControlPlayback)
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $player.volume).frame(width: 58).accessibilityLabel("Volume")
                Divider().frame(height: 22)
                inspectorButton(.lyrics, "quote.bubble", "Lyrics")
                inspectorButton(.queue, "list.bullet", "Play queue")
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 17).padding(.vertical, 11).background(.regularMaterial)
    }

    private func inspectorButton(_ mode: Inspector, _ symbol: String, _ title: String) -> some View {
        Button { inspector = inspector == mode ? nil : mode } label: {
            Image(systemName: symbol).foregroundStyle(inspector == mode ? Color.echoAccent : .primary)
        }.help(title).accessibilityLabel(title)
    }
}

struct Scrubber: View {
    @EnvironmentObject private var player: Player
    @ObservedObject var head: Playhead
    @ViewState private var tentative: Double?
    @ViewState private var dragging = false
    var body: some View {
        VStack(spacing: 1) {
            Slider(value: Binding(get: { tentative ?? min(head.seconds, max(1, player.duration)) }, set: { position in
                if dragging { tentative = position } else { player.seek(position) }
            }),
                   in: 0...max(1, player.duration), onEditingChanged: { editing in
                dragging = editing
                if !editing, let position = tentative { player.seek(position); tentative = nil }
            })
            .disabled(player.duration <= 0 || player.loading || player.failure != nil)
            .accessibilityLabel("Playback position")
            .accessibilityValue(clockText(tentative ?? head.seconds))
            HStack {
                Text(clockText(tentative ?? head.seconds))
                Spacer()
                Text(clockText(player.duration))
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject private var player: Player
    let mode: Inspector
    let close: () -> Void
    @ViewState private var lyrics: Lyrics?
    @ViewState private var lyricsError: String?
    @ViewState private var retry = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(mode == .queue ? "Play queue" : "Lyrics").font(.title2.bold())
                Spacer()
                Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Close panel")
            }
            if mode == .queue {
                if player.queue.isEmpty { Text("Play a song to start your queue.").foregroundStyle(.secondary) }
                ScrollView {
                    LazyVStack(alignment: .leading) {
                        ForEach(Array(player.queue.enumerated()), id: \.offset) { offset, track in
                            HStack {
                                Button { player.start(offset) } label: {
                                    HStack {
                                        if player.index == offset { Image(systemName: "waveform").foregroundStyle(Color.echoAccent) }
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(track.title).fontWeight(.medium).lineLimit(2)
                                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if let current = player.index, offset > current {
                                    Button { player.removeUpcoming(offset) } label: { Image(systemName: "minus.circle") }
                                        .buttonStyle(.plain).accessibilityLabel("Remove \(track.title) from queue")
                                }
                            }.padding(.vertical, 5)
                        }
                    }
                }
            } else if player.current == nil { Text("Play a song to see its lyrics.").foregroundStyle(.secondary) }
            else if let lyricsError {
                Text(lyricsError).foregroundStyle(.secondary)
                Button("Try again") { retry += 1 }
            } else if let lyrics {
                switch lyrics {
                case .instrumental: Text("Instrumental").foregroundStyle(.secondary)
                case .plain(let text): ScrollView { Text(text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                case .synced(let lines): SyncedLyrics(lines: lines, head: player.head)
                }
            } else { ProgressView("Finding lyrics…").controlSize(.small) }
            Spacer(minLength: 0)
        }
        .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: Lookup(mode: mode, track: player.current, retry: retry)) {
            lyrics = nil
            lyricsError = nil
            guard mode == .lyrics, let track = player.current else { return }
            if case .youtube(let id) = track.source, track.title == id { return }
            do {
                let result = try await Lyrics.fetch(track)
                try Task.checkCancellation()
                lyrics = result
            } catch { if !Task.isCancelled { lyricsError = error.localizedDescription } }
        }
    }
    private struct Lookup: Equatable { let mode: Inspector; let track: Track?; let retry: Int }
}

struct SyncedLyrics: View {
    @EnvironmentObject private var player: Player
    let lines: [LyricLine]
    @ObservedObject var head: Playhead
    var body: some View {
        let active = lines.lastIndex { $0.time <= head.seconds }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(lines.indices, id: \.self) { index in
                        Button { player.seek(lines[index].time) } label: {
                            Text(lines[index].text.isEmpty ? "♪" : lines[index].text)
                                .font(.body.weight(index == active ? .bold : .regular))
                                .foregroundStyle(index == active ? .primary : .secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).id(index)
                    }
                }
            }
            .onChange(of: active, initial: true) { _, line in
                if let line { proxy.scrollTo(line, anchor: .center) }
            }
        }
    }
}
