import Foundation
import Testing

@testable import EchoMusic

@Test func roomWireMatchesAndroidProtobufEnvelope() throws {
    let encoded = try RoomWire.encode(
        type: "join_room", payload: ["room_code": "ABCDEFGH", "username": "Alice"], protobuf: true)
    // Envelope(type = join_room, payload = JoinRoomPayload(...)).
    let expected: [UInt8] = [
        10, 9, 106, 111, 105, 110, 95, 114, 111, 111, 109, 18, 17, 10, 8, 65, 66, 67, 68, 69, 70, 71, 72, 18, 5, 65,
        108, 105, 99, 101,
    ]
    #expect(Array(encoded) == expected)
    let decoded = try RoomWire.decode(encoded)
    #expect(decoded.type == "join_room")
    #expect(decoded.payload["room_code"] as? String == "ABCDEFGH")
    #expect(decoded.payload["username"] as? String == "Alice")
}

@Test func roomWirePreservesOptionalZeroAndRejectsMalformedFrames() throws {
    let data = try RoomWire.encode(type: "sync_playback", payload: ["action": "seek", "position": 0], protobuf: true)
    let decoded = try RoomWire.decode(data)
    #expect((decoded.payload["position"] as? Int64) == 0)
    #expect(throws: (any Error).self) { try RoomWire.decode(Data([0x0a, 0x80])) }
    let json = try RoomWire.encode(type: "ping", payload: ["sequence": 2], protobuf: false)
    #expect(try RoomWire.decode(json).type == "ping")
}

@Test func roomWireDecodesGzipEnvelope() throws {
    let frame = Data([
        10, 12, 114, 111, 111, 109, 95, 99, 114, 101, 97, 116, 101, 100, 18, 39, 31, 139, 8, 0, 0, 0, 0, 0, 2, 19, 227,
        226, 112, 116, 114, 118, 113, 117, 115, 247, 16, 98, 42, 53, 148, 98, 46, 201, 207, 6, 0, 176, 122, 126, 175,
        19, 0, 0, 0, 24, 1,
    ])
    let message = try RoomWire.decode(frame)
    #expect(message.type == "room_created")
    #expect(message.payload["room_code"] as? String == "ABCDEFGH")
    #expect(message.payload["session_token"] as? String == "tok")
}

@Test func roomStateRevisionDoesNotGrantControl() throws {
    // Join-approved payload with a state whose field 10 contains Metroserver revision 1.
    let state = Data([10, 8] + Array("ABCDEFGH".utf8) + [18, 1, 104, 80, 1])
    let body = Data([10, 8] + Array("ABCDEFGH".utf8) + [18, 1, 117, 26, 1, 116, 34, UInt8(state.count)]) + state
    let frame = Data([10, 13] + Array("join_approved".utf8) + [18, UInt8(body.count)]) + body
    let decoded = try RoomWire.decode(frame)
    let room = try #require(decoded.payload["state"] as? [String: Any])
    #expect(room["allow_participant_control"] as? Bool == false)
}

@Test func sparseLegacyJSONUsesAndroidDefaultsWithoutInventingQueue() throws {
    let json =
        #"{"type":"join_approved","payload":{"state":{"room_code":"ABCDEFGH","host_id":"host","users":[{"user_id":"host","username":"Alice","is_host":true}],"is_playing":false,"position":0,"last_update":1}}}"#
    let payload = try RoomWire.decode(Data(json.utf8)).payload
    let state = try #require(payload["state"] as? [String: Any])
    let encoded = try JSONSerialization.data(withJSONObject: state)
    let room = try JSONDecoder().decode(RoomState.self, from: encoded)
    #expect(room.volume == 1)
    #expect(room.queue.isEmpty)
    #expect(room.users.first?.isConnected == true)
    #expect(room.allowParticipantControl == false)
    let actionPayload = try RoomWire.decode(Data(#"{"type":"sync_playback","payload":{"action":"play"}}"#.utf8)).payload
    let action = try JSONDecoder().decode(RoomAction.self, from: JSONSerialization.data(withJSONObject: actionPayload))
    #expect(action.replaceQueue == false)
    #expect(action.queue == nil)
}

@Test func roomWireReadsGzippedLegacyJSON() throws {
    let data = try #require(Data(base64Encoded: "H4sIAAAAAAACE6tWKqksSFWyUirIz0tX0lEqSKzMyU9MUbKqVipOLSxNzUsGShrV1gIAbYEFNCgAAAA="))
    let frame = try RoomWire.decode(data)
    #expect(frame.type == "pong" && !frame.protobuf)
    #expect(frame.payload["sequence"] as? Int == 2)
}
