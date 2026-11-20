import AVFoundation
import Foundation
import Testing
@testable import EchoMusic

/// Run with ECHO_ROOM_TEST_URL pointing at a private Metroserver. Catalog IDs resolve to
/// generated audio on each client, so this checks the room independently of music services.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ECHO_ROOM_TEST_URL"] != nil))
func roomPlaybackThroughMetroserver() async throws {
    let server = try #require(ProcessInfo.processInfo.environment["ECHO_ROOM_TEST_URL"])
    let audio = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: audio) }
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
    do {
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(buffer.frameLength))
        try file.write(from: buffer)
    }

    let host = RoomSession()
    let guest = RoomSession()
    let leader = Player(systemControls: false, offlineURL: { _ in audio })
    let follower = Player(systemControls: false, offlineURL: { _ in audio })
    leader.volume = 0
    follower.volume = 0
    leader.attachRoom(host)
    follower.attachRoom(guest)
    defer { guest.leave(); host.leave(); leader.pause(); follower.pause() }
    func wait(_ description: String, for condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            if let failure = host.errorMessage ?? guest.errorMessage ?? leader.failure ?? follower.failure {
                throw EchoError("\(description): \(failure)")
            }
            guard ContinuousClock.now < deadline else { throw EchoError("Timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    let a = Track(source: .youtube("abcdefghi01"), title: "First", artist: "Fixture", duration: 20)
    let b = Track(source: .youtube("abcdefghi02"), title: "Second", artist: "Fixture", duration: 20)
    host.create(username: "Mac host", serverURL: server)
    try await wait("room creation") { host.isAttached }
    leader.play([a, a, b])
    try await wait("host playback") { leader.roomPosition > 0.1 && host.state?.currentTrack?.id == a.roomTrackID }
    guest.join(code: try #require(host.state?.roomCode), username: "Mac guest", serverURL: server)
    try await wait("approval request") { !host.pendingJoins.isEmpty }
    host.rejectJoin(userId: try #require(host.pendingJoins.first?.userId))
    try await wait("rejection") { guest.connection == .error }
    #expect(!guest.joinPending && guest.role == .none)
    guest.join(code: try #require(host.state?.roomCode), username: "Mac guest", serverURL: server)
    try await wait("second approval request") { !host.pendingJoins.isEmpty }
    host.approveJoin(userId: try #require(host.pendingJoins.first?.userId))
    try await wait("late join while playing") { guest.isAttached && follower.roomPlaying }
    #expect(follower.queue.map(\.roomTrackID) == [a.roomTrackID, a.roomTrackID, b.roomTrackID])
    #expect(!guest.canControlPlayback)
    follower.pause()
    #expect(follower.wantsPlayback)
    leader.pause()
    try await wait("host pause") { !follower.wantsPlayback }
    leader.seek(5.25)
    try await wait("paused seek") { abs(follower.roomPosition - 5.25) < 0.08 }
    leader.seek(0)
    try await wait("seek to zero") { follower.roomPosition < 0.08 }
    leader.start(2)
    try await wait("new track after buffering") { follower.current?.roomTrackID == b.roomTrackID && follower.roomPlaying }
    guest.leave()
    try await wait("guest departure") { host.state?.users.count == 1 }
    #expect(guest.role == .none)
}
