import AVFoundation
import MediaPlayer
import SwiftUI

@MainActor
final class Playhead: ObservableObject {
    @Published var seconds = 0.0
}

@MainActor
final class Player: ObservableObject {
    @Published private(set) var queue: [Track] = []
    @Published private(set) var index: Int?
    @Published private(set) var duration = 0.0
    @Published private(set) var wantsPlayback = false
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published var roomPlaybackIssue: String?
    @Published var volume: Double = 0.8 { didSet { engine.volume = Float(volume) } }
    let head = Playhead()
    private let engine = AVPlayer()
    private let offlineURL: (Track) -> URL?
    private let systemControls: Bool
    private var timeObserver: Any?
    private var rateObserver: NSKeyValueObservation?
    private var itemObserver: NSKeyValueObservation?
    private var itemNotifications: [NSObjectProtocol] = []
    private var request: Task<Void, Never>?
    private var generation = UUID()
    private var ended = false
    private var roomPlayback: RoomPlayback?
    private var roomSeek = UUID()
    private(set) var roomSeekInProgress = false

    var roomReady: Bool { engine.currentItem?.status == .readyToPlay && !loading && failure == nil }
    var roomPlaying: Bool { wantsPlayback && engine.timeControlStatus == .playing }
    var roomPosition: Double {
        let seconds = engine.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : head.seconds
    }
    var roomTrackGeneration: UUID { generation }

    func attachRoom(_ session: RoomSession) {
        roomPlayback = RoomPlayback(player: self, session: session)
    }

    private func roomAllows(_ track: Track? = nil) -> Bool {
        roomPlayback?.allowsLocalControl(track: track) != false
    }

    func setRoomQueue(_ tracks: [Track], at selected: Int?, reload: Bool = false) {
        queue = tracks
        if let selected, reload {
            start(selected, autoplay: false)
        } else {
            index = selected
            if selected == nil {
                request?.cancel()
                generation = UUID()
                roomSeek = UUID()
                roomSeekInProgress = false
                itemObserver = nil
                for token in itemNotifications { NotificationCenter.default.removeObserver(token) }
                itemNotifications.removeAll()
                engine.pause()
                engine.replaceCurrentItem(with: nil)
                wantsPlayback = false
                loading = false
                failure = nil
                duration = 0
                head.seconds = 0
            }
            updateSystemState()
        }
    }

    func applyRoomPosition(_ seconds: Double?, playing: Bool) {
        if !playing {
            wantsPlayback = false
            engine.pause()
            updateSystemState()
        }
        guard roomReady else { return }
        if seconds == nil, playing && roomSeekInProgress { return }
        let ticket = UUID()
        roomSeek = ticket
        roomSeekInProgress = seconds != nil
        engine.currentItem?.cancelPendingSeeks()
        if playing { wantsPlayback = true }
        if let seconds {
            let position = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
            ended = false
            head.seconds = position
            engine.seek(to: CMTime(seconds: position, preferredTimescale: 1000),
                        toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
                Task { @MainActor in
                    guard let self, self.roomSeek == ticket else { return }
                    self.roomSeekInProgress = false
                    if finished && self.wantsPlayback { self.engine.play() }
                    self.updateSystemState()
                    self.roomPlayback?.playerStatusChanged()
                }
            }
        } else if playing && !roomPlaying {
            engine.play()
        }
        updateSystemState()
    }

    func setRoomRate(_ rate: Float) {
        if roomPlaying { engine.rate = rate }
    }

    func disconnectRoomPlayback() {
        roomSeek = UUID()
        roomSeekInProgress = false
        engine.currentItem?.cancelPendingSeeks()
        if wantsPlayback && roomReady { engine.play() }
    }

    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    var current: Track? { index.flatMap { queue.indices.contains($0) ? queue[$0] : nil } }
    private var nextIndex: Int? {
        guard let index else { return nil }
        let upcoming = queue.indices.dropFirst(index + 1)
        if roomPlayback?.expectsSharedTracks == true {
            return upcoming.first { queue[$0].roomTrackID != nil }
        }
        return upcoming.first
    }

    var hasNext: Bool { nextIndex != nil }

    init(systemControls: Bool = true, offlineURL: @escaping (Track) -> URL? = { _ in nil }) {
        self.offlineURL = offlineURL
        self.systemControls = systemControls
        engine.volume = Float(volume)
        timeObserver = engine.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.35, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.engine.currentItem != nil else { return }
                let time = self.engine.currentTime().seconds
                if time.isFinite { self.head.seconds = max(0, time) }
            }
        }
        rateObserver = engine.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in
                self?.updateSystemState()
                self?.roomPlayback?.playerStatusChanged()
            }
        }
        if systemControls { registerCommands() }
    }

    deinit {
        request?.cancel()
        if let timeObserver { engine.removeTimeObserver(timeObserver) }
        for token in itemNotifications { NotificationCenter.default.removeObserver(token) }
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    func play(_ tracks: [Track], at selected: Int = 0) {
        guard tracks.indices.contains(selected), roomAllows(tracks[selected]) else { return }
        queue = tracks
        start(selected)
    }

    func enqueue(_ track: Track, next: Bool = false) {
        guard roomAllows(track) else { return }
        guard let index else { play([track]); return }
        queue.insert(track, at: next ? index + 1 : queue.endIndex)
        updateSystemState()
        roomPlayback?.localQueueChanged()
    }

    func removeUpcoming(_ offset: Int) {
        guard let index, offset > index, queue.indices.contains(offset), roomAllows() else { return }
        queue.remove(at: offset)
        updateSystemState()
        roomPlayback?.localQueueChanged()
    }

    func start(_ selected: Int) {
        guard queue.indices.contains(selected), roomAllows(queue[selected]) else { return }
        start(selected, autoplay: true)
    }

    private func start(_ selected: Int, autoplay: Bool) {
        request?.cancel()
        let ticket = UUID()
        generation = ticket
        roomSeek = UUID()
        roomSeekInProgress = false
        itemObserver = nil
        for token in itemNotifications { NotificationCenter.default.removeObserver(token) }
        itemNotifications.removeAll()
        engine.pause()
        engine.replaceCurrentItem(with: nil)
        index = selected
        let track = queue[selected]
        ended = false
        failure = nil
        wantsPlayback = autoplay
        loading = true
        head.seconds = 0
        duration = track.duration ?? 0
        updateSystemState()
        if autoplay { roomPlayback?.localTrackChanged() }
        request = Task {
            do {
                let url: URL
                switch track.source {
                case .file(let file):
                    guard FileManager.default.isReadableFile(atPath: file.path) else {
                        throw EchoError("The file could not be opened. If it moved, import it from its new location.")
                    }
                    url = file
                case .youtube(let id):
                    if let file = offlineURL(track) {
                        url = file
                        break
                    }
                    let stream = try await Catalog.shared.stream(for: id)
                    try Task.checkCancellation()
                    guard generation == ticket else { return }
                    url = stream.url
                    if track.title == id, let index, queue.indices.contains(index) { queue[index] = stream.track }
                    duration = track.duration ?? stream.track.duration ?? 0
                }
                guard generation == ticket, !Task.isCancelled else { return }
                load(AVPlayerItem(url: url), ticket: ticket)
            } catch {
                guard generation == ticket, !Task.isCancelled else { return }
                fail(error.localizedDescription)
            }
        }
    }

    private func load(_ item: AVPlayerItem, ticket: UUID) {
        engine.replaceCurrentItem(with: item)
        itemObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                switch item.status {
                case .readyToPlay:
                    self.loading = false
                    let length = item.duration.seconds
                    if length.isFinite && length > 0 { self.duration = length }
                    if self.wantsPlayback { self.engine.play() }
                    self.updateSystemState()
                    self.roomPlayback?.playerStatusChanged()
                case .failed: self.fail(item.error?.localizedDescription ?? "This audio could not be played.")
                default: break
                }
            }
        }
        let center = NotificationCenter.default
        itemNotifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                if self.roomPlayback?.expectsRemoteTrackChanges == true {
                    self.ended = true
                    self.head.seconds = self.duration
                    self.wantsPlayback = false
                    self.updateSystemState()
                } else if let next = self.nextIndex {
                    self.start(next)
                } else {
                    self.ended = true
                    self.head.seconds = self.duration
                    self.pause()
                }
            }
        })
        itemNotifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription
            Task { @MainActor in
                guard let self, self.generation == ticket else { return }
                self.fail(message ?? "The stream was interrupted. Try playing this song again.")
            }
        })
    }

    private func fail(_ message: String) {
        loading = false
        failure = message
        wantsPlayback = false
        engine.pause()
        updateSystemState()
        roomPlayback?.playerStatusChanged()
    }

    func toggle() { wantsPlayback ? pause() : resume() }

    func pause() {
        guard roomAllows() else { return }
        roomSeek = UUID()
        roomSeekInProgress = false
        wantsPlayback = false
        engine.pause()
        updateSystemState()
        roomPlayback?.localPlayStateChanged()
    }

    func resume() {
        guard let index, roomAllows(current) else { return }
        if failure != nil || ended { start(index); return }
        wantsPlayback = true
        if !loading { engine.play() }
        updateSystemState()
        roomPlayback?.localPlayStateChanged()
    }

    func previous() {
        guard let index else { return }
        if head.seconds > 3 || index == 0 { seek(0) } else { start(index - 1) }
    }

    func next() { if let nextIndex { start(nextIndex) } }

    func seek(_ seconds: Double) {
        guard roomAllows(), seconds.isFinite, duration > 0, roomReady else { return }
        roomSeek = UUID()
        roomSeekInProgress = false
        let position = min(max(0, seconds), duration)
        ended = false
        head.seconds = position
        engine.seek(to: CMTime(seconds: position, preferredTimescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        updateSystemState()
        roomPlayback?.localSeeked(to: position)
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        func bind(_ command: MPRemoteCommand, _ action: @escaping @MainActor (Player) -> Void) {
            let target = command.addTarget { [weak self] _ in
                Task { @MainActor in if let self { action(self) } }
                return .success
            }
            remoteTargets.append((command, target))
        }
        bind(center.playCommand) { $0.resume() }
        bind(center.pauseCommand) { $0.pause() }
        bind(center.togglePlayPauseCommand) { $0.toggle() }
        bind(center.previousTrackCommand) { $0.previous() }
        bind(center.nextTrackCommand) { $0.next() }
        let command = center.changePlaybackPositionCommand
        let target = command.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            Task { @MainActor in self?.seek(event.positionTime) }
            return .success
        }
        remoteTargets.append((command, target))
        updateSystemState()
    }

    private func updateSystemState() {
        guard systemControls else { return }
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.isEnabled = current != nil && !wantsPlayback
        commands.pauseCommand.isEnabled = wantsPlayback
        commands.togglePlayPauseCommand.isEnabled = current != nil
        commands.previousTrackCommand.isEnabled = current != nil
        commands.nextTrackCommand.isEnabled = hasNext
        commands.changePlaybackPositionCommand.isEnabled = duration > 0 && !loading && failure == nil
        guard let current else { return }
        let info = MPNowPlayingInfoCenter.default()
        let playing = engine.timeControlStatus == .playing
        info.nowPlayingInfo = [
            MPMediaItemPropertyTitle: current.title, MPMediaItemPropertyArtist: current.artist,
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: head.seconds,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0
        ]
        info.playbackState = playing ? .playing : .paused
    }
}
