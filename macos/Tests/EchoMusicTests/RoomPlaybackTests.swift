import Testing
@testable import EchoMusic

@Suite
struct RoomPlaybackTests {
    @Test func playingAnchorProjectsFromServerTimeAndMonotonicReceipt() {
        let anchor = RoomPlayheadAnchor(position: 12_345, playing: true, receivedAt: 1_500_000_000,
                                        serverTime: 2_000_000, serverNow: 2_000_065, oneWay: 5, snapshot: false)
        #expect(abs(anchor.seconds(at: 1_720_000_000, duration: 30) - 12.630) < 0.000_001)
        #expect(abs(anchor.seconds(at: 1_720_000_000, duration: 12.6) - 12.6) < 0.000_001)
    }

    @Test func staleLiveTimingUsesTransitButSnapshotsAcceptOlderAnchors() {
        let live = RoomPlayheadAnchor(position: 10_000, playing: true, receivedAt: 0,
                                      serverTime: 1_000, serverNow: 20_000, oneWay: 10, snapshot: false)
        let snapshot = RoomPlayheadAnchor(position: 10_000, playing: true, receivedAt: 0,
                                          serverTime: 1_000, serverNow: 20_000, oneWay: 10, snapshot: true)
        #expect(abs(live.seconds(at: 0, duration: 0) - 10.01) < 0.000_001)
        #expect(abs(snapshot.seconds(at: 0, duration: 0) - 29) < 0.000_001)
    }

    @Test func bufferBarrierReportsActualTrackOnceAndKeepsLatestPausedAnchor() {
        let playing = RoomPlayheadAnchor(position: 10_000, playing: true, receivedAt: 0,
                                         serverTime: nil, serverNow: nil, oneWay: 0, snapshot: false)
        let paused = RoomPlayheadAnchor(position: 12_500, playing: false, receivedAt: 1_000,
                                        serverTime: nil, serverNow: nil, oneWay: 0, snapshot: false)
        var pending = BufferedRoomPlayback(trackID: "a", anchor: playing, needsBarrier: true)
        let mismatchedReady = pending.localReady(trackID: "b")
        let firstReady = pending.localReady(trackID: "a")
        let duplicateReady = pending.localReady(trackID: "a")
        #expect(!mismatchedReady)
        #expect(firstReady)
        #expect(!duplicateReady)
        pending.complete(trackID: "b")
        #expect(pending.waitingForRoom)
        pending.anchor = paused
        pending.complete(trackID: "a")
        #expect(!pending.waitingForRoom)
        #expect(pending.anchor.seconds(at: 10_000_000_000, duration: 30) == 12.5)
    }

    @Test func incomingQueueRetainsTheKnownOccurrenceAndPrependsWhenUpcoming() {
        let current = ["a", "b", "a", "c", "a"]
        #expect(incomingRoomQueueIndex(current, activeID: "a", currentIDs: current,
                                       currentIndex: 2, upcoming: false) == 2)
        #expect(incomingRoomQueueIndex(["c", "a"], activeID: "a", currentIDs: current,
                                            currentIndex: 2, upcoming: false) == nil)
        #expect(incomingRoomQueueIndex(["a", "c"], activeID: "a", currentIDs: current,
                                            currentIndex: 2, upcoming: true) == nil)
    }
}
