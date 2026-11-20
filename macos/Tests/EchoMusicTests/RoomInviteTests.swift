import Testing
@testable import EchoMusic

struct RoomInviteTests {
    @Test func acceptsAndroidInviteFormats() {
        #expect(RoomInvite.code(from: " ab12cd34 ") == "AB12CD34")
        #expect(RoomInvite.code(from: "echomusic://listen?room=ab12cd34") == "AB12CD34")
        #expect(RoomInvite.code(from: "https://metroserverx.meowery.eu/listen/ab12cd34") == "AB12CD34")
        #expect(RoomInvite.code(from: "https://metroserverx.meowery.eu/listen?code=%41B12CD34") == "AB12CD34")
        #expect(RoomInvite.code(from: "https://metroserverx.meowery.eu/listen?room=AB12CD34") == "AB12CD34")
    }

    @Test func rejectsMalformedAndUntrustedInvites() {
        for value in [
            "https://example.com/listen?code=AB12CD34",
            "https://metroserverx.meowery.eu/unrelated?code=AB12CD34",
            "https://metroserverx.meowery.eu/listen?code=AB12CD34&room=ZZZZZZZZ",
            "https://metroserverx.meowery.eu/listen?code=AB12",
            "https://metroserverx.meowery.eu/listen?code=%",
            "https://user@metroserverx.meowery.eu/listen/AB12CD34",
            "https://metroserverx.meowery.eu:443/listen/AB12CD34",
            "file:///listen/AB12CD34",
            "AB12-CD34",
            "ßAB12CD",
            "https://metroserverx.meowery.eu/listen/AB12CD34/extra",
        ] {
            #expect(RoomInvite.code(from: value) == nil, "Unexpectedly accepted: \(value)")
        }
    }
}
