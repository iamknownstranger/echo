import CZlib
import Foundation

// Android-compatible envelopes: binary Protobuf for Metroserver, plus JSON decoding for compatible relays.
enum RoomWire {
    enum WireError: Error { case invalid, unsupportedCompression }
    private enum Kind { case string, int, bool, float, message(String), strings, messages(String) }
    private typealias Field = (String, Kind)
    private static let track: [Int: Field] = [
        1: ("id", .string), 2: ("title", .string), 3: ("artist", .string), 4: ("album", .string), 5: ("duration", .int),
        6: ("thumbnail", .string), 7: ("suggested_by", .string),
    ]
    private static let user: [Int: Field] = [
        1: ("user_id", .string), 2: ("username", .string), 3: ("is_host", .bool), 4: ("is_connected", .bool),
    ]
    private static let state: [Int: Field] = [
        1: ("room_code", .string), 2: ("host_id", .string), 3: ("users", .messages("user")),
        4: ("current_track", .message("track")), 5: ("is_playing", .bool), 6: ("position", .int),
        7: ("last_update", .int), 8: ("volume", .float), 9: ("queue", .messages("track")),
    ]
    private static let action: [Int: Field] = [
        1: ("action", .string), 2: ("track_id", .string), 3: ("position", .int), 4: ("track_info", .message("track")),
        5: ("insert_next", .bool), 6: ("queue", .messages("track")), 7: ("queue_title", .string), 8: ("volume", .float),
        9: ("server_time", .int), 11: ("captured_at_server_time", .int), 12: ("replace_queue", .bool),
        13: ("origin_user_id", .string),
    ]
    private static func schema(_ name: String) -> [Int: Field] {
        switch name {
        case "track": return track
        case "user": return user
        case "state": return state
        case "playback_action", "sync_playback": return action
        case "create_room": return [1: ("username", .string)]
        case "join_room": return [1: ("room_code", .string), 2: ("username", .string)]
        case "approve_join", "kick_user", "reject_join": return [1: ("user_id", .string), 2: ("reason", .string)]
        case "transfer_host": return [1: ("new_host_id", .string)]
        case "update_room_settings", "room_settings_changed": return [1: ("allow_participant_control", .bool)]
        case "ping": return [1: ("client_time", .int), 2: ("sequence", .int)]
        case "pong":
            return [
                1: ("client_time", .int), 2: ("server_receive_time", .int), 3: ("server_send_time", .int),
                4: ("sequence", .int),
            ]
        case "buffer_ready", "buffer_complete": return [1: ("track_id", .string)]
        case "buffer_wait": return [1: ("track_id", .string), 2: ("waiting_for", .strings)]
        case "reconnect": return [1: ("session_token", .string)]
        case "room_created": return [1: ("room_code", .string), 2: ("user_id", .string), 3: ("session_token", .string)]
        case "join_request", "user_joined", "user_left", "user_reconnected", "user_disconnected":
            return [1: ("user_id", .string), 2: ("username", .string)]
        case "join_approved":
            return [
                1: ("room_code", .string), 2: ("user_id", .string), 3: ("session_token", .string),
                4: ("state", .message("state")),
            ]
        case "reconnected":
            return [
                1: ("room_code", .string), 2: ("user_id", .string), 3: ("state", .message("state")),
                4: ("is_host", .bool),
            ]
        case "join_rejected", "kicked": return [1: ("reason", .string)]
        case "error": return [1: ("code", .string), 2: ("message", .string)]
        case "host_changed": return [1: ("new_host_id", .string), 2: ("new_host_name", .string)]
        case "sync_state":
            return [
                1: ("current_track", .message("track")), 2: ("is_playing", .bool), 3: ("position", .int),
                4: ("last_update", .int), 5: ("queue", .messages("track")), 6: ("volume", .float),
            ]
        default: return [:]
        }
    }
    static func encode(type: String, payload: [String: Any]?, protobuf: Bool) throws -> Data {
        if !protobuf {
            return try JSONSerialization.data(withJSONObject: ["type": type, "payload": (payload as Any?) ?? NSNull()])
        }
        let body = try encodeMessage(payload ?? [:], schema(type))
        return field(1, Data(type.utf8)) + field(2, body)
    }
    static func decode(_ frame: Data) throws -> (type: String, payload: [String: Any], protobuf: Bool) {
        let data = frame.starts(with: [0x1f, 0x8b]) ? try gunzip(frame) : frame
        if data.first == 123 {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = obj["type"] as? String
            else { throw WireError.invalid }
            var payload = obj["payload"] as? [String: Any] ?? [:]
            if type == "join_approved" || type == "reconnected", var state = payload["state"] as? [String: Any] {
                defaults(&state, ["volume": 1, "queue": [], "allow_participant_control": false])
                if let users = state["users"] as? [[String: Any]] {
                    state["users"] = users.map { user in
                        var user = user
                        defaults(&user, ["is_connected": true])
                        return user
                    }
                }
                payload["state"] = state
            }
            if type == "sync_playback" || type == "playback_action" {
                defaults(&payload, ["replace_queue": false])
            }
            return (type, payload, false)
        }
        let envelope = try parse(data)
        guard let nameData = envelope[1]?.first?.data, let type = String(data: nameData, encoding: .utf8) else {
            throw WireError.invalid
        }
        var body = envelope[2]?.first?.data ?? Data()
        if envelope[3]?.first?.number == 1 { body = try gunzip(body) }
        var payload = try decodeMessage(body, schema(type))
        // Proto3 omits defaults, while Android's JSON models require these fields.
        if type == "sync_state" {
            defaults(&payload, ["is_playing": false, "position": 0, "last_update": 0, "queue": []])
        }
        if type == "sync_playback" { defaults(&payload, ["replace_queue": false]) }
        return (type, payload, true)
    }
    private static func gunzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WireError.invalid
        }
        defer { inflateEnd(&stream) }
        var output = Data()
        return try input.withUnsafeBytes { raw in
            stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(input.count)
            var status: Int32 = Z_OK
            while status == Z_OK {
                var chunk = [UInt8](repeating: 0, count: 16384)
                let produced = chunk.withUnsafeMutableBytes { buf -> Int in
                    stream.next_out = buf.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buf.count)
                    status = inflate(&stream, Z_NO_FLUSH)
                    return buf.count - Int(stream.avail_out)
                }
                output.append(contentsOf: chunk.prefix(produced))
                guard output.count <= 2 * 1024 * 1024 else { throw WireError.invalid }
            }
            guard status == Z_STREAM_END else { throw WireError.invalid }
            return output
        }
    }
    private static func defaults(_ object: inout [String: Any], _ values: [String: Any]) {
        for (key, value) in values where object[key] == nil { object[key] = value }
    }
    private static func decodeMessage(_ data: Data, _ fields: [Int: Field]) throws -> [String: Any] {
        let parsed = try parse(data)
        var result: [String: Any] = [:]
        for (number, (name, kind)) in fields {
            let values = parsed[number] ?? []
            switch kind {
            case .string: if let d = values.first?.data { result[name] = String(data: d, encoding: .utf8) }
            case .int: if let n = values.first?.number { result[name] = Int64(bitPattern: n) }
            case .bool: if let n = values.first?.number { result[name] = n != 0 }
            case .float:
                if let n = values.first?.number { result[name] = Float(bitPattern: UInt32(truncatingIfNeeded: n)) }
            case .message(let schemaName):
                if let d = values.first?.data { result[name] = try decodeMessage(d, schema(schemaName)) }
            case .strings: result[name] = values.compactMap { $0.data.flatMap { String(data: $0, encoding: .utf8) } }
            case .messages(let schemaName):
                result[name] = try values.compactMap { try $0.data.map { try decodeMessage($0, schema(schemaName)) } }
            }
        }
        if fields[1]?.0 == "room_code" && fields[3]?.0 == "users" {
            defaults(
                &result,
                [
                    "room_code": "", "host_id": "", "users": [], "is_playing": false, "position": 0, "last_update": 0,
                    "volume": 1, "queue": [], "allow_participant_control": false,
                ])
        }
        if fields[1]?.0 == "user_id" && fields[3]?.0 == "is_host" {
            defaults(&result, ["user_id": "", "username": "", "is_host": false, "is_connected": false])
        }
        if fields[1]?.0 == "id" { defaults(&result, ["id": "", "title": "", "artist": "", "duration": 0]) }
        return result
    }
    private struct Value {
        var number: UInt64?
        var data: Data?
    }
    private static func parse(_ data: Data) throws -> [Int: [Value]] {
        let bytes = [UInt8](data)
        var i = 0
        var result: [Int: [Value]] = [:]
        func read() throws -> UInt64 {
            var n: UInt64 = 0
            var shift: UInt64 = 0
            while i < bytes.count && shift < 64 {
                let b = bytes[i]
                i += 1
                n |= UInt64(b & 127) << shift
                if b & 128 == 0 { return n }
                shift += 7
            }
            throw WireError.invalid
        }
        while i < bytes.count {
            let key = try read()
            let number = Int(key >> 3)
            guard number > 0 else { throw WireError.invalid }
            let value: Value
            switch key & 7 {
            case 0: value = Value(number: try read(), data: nil)
            case 1:
                guard i + 8 <= bytes.count else { throw WireError.invalid }
                var n: UInt64 = 0
                for j in 0..<8 { n |= UInt64(bytes[i + j]) << (j * 8) }
                i += 8
                value = Value(number: n, data: nil)
            case 2:
                let count = try read()
                guard count <= UInt64(bytes.count - i) else { throw WireError.invalid }
                value = Value(number: nil, data: Data(bytes[i..<(i + Int(count))]))
                i += Int(count)
            case 5:
                guard i + 4 <= bytes.count else { throw WireError.invalid }
                var n: UInt64 = 0
                for j in 0..<4 { n |= UInt64(bytes[i + j]) << (j * 8) }
                i += 4
                value = Value(number: n, data: nil)
            default: throw WireError.invalid
            }
            result[number, default: []].append(value)
        }
        return result
    }
    private static func varint(_ number: UInt64) -> Data {
        var n = number
        var bytes: [UInt8] = []
        while n >= 128 {
            bytes.append(UInt8(n & 127) | 128)
            n >>= 7
        }
        bytes.append(UInt8(n))
        return Data(bytes)
    }
    private static func field(_ number: Int, _ data: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(data.count)) + data
    }
    private static func encodeMessage(_ object: [String: Any], _ fields: [Int: Field]) throws -> Data {
        var out = Data()
        for number in fields.keys.sorted() {
            guard let (name, kind) = fields[number], let value = object[name], !(value is NSNull) else { continue }
            switch kind {
            case .string: if let v = value as? String { out += field(number, Data(v.utf8)) }
            case .int, .bool:
                if let v = value as? NSNumber {
                    out += varint(UInt64(number << 3))
                    out += varint(v.uint64Value)
                }
            case .float:
                if let v = value as? NSNumber {
                    out += varint(UInt64(number << 3 | 5))
                    var bits = v.floatValue.bitPattern.littleEndian
                    out += withUnsafeBytes(of: &bits) { Data($0) }
                }
            case .message(let s):
                if let v = value as? [String: Any] { out += field(number, try encodeMessage(v, schema(s))) }
            case .strings: if let v = value as? [String] { for item in v { out += field(number, Data(item.utf8)) } }
            case .messages(let s):
                if let v = value as? [[String: Any]] {
                    for item in v { out += field(number, try encodeMessage(item, schema(s))) }
                }
            }
        }
        return out
    }
}
