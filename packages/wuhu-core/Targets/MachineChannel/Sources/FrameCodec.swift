import JSONValue
import MachineContract

public enum FrameCodec {
  public static func encode(_ frame: Frame) -> [UInt8] {
    let value = try! JSONValueEncoder().encode(frame)
    return Array(value.jsonString().utf8)
  }

  public static func decode(_ bytes: [UInt8]) throws(ChannelError) -> Frame {
    guard let value = JSONValue.parse(String(decoding: bytes, as: UTF8.self)),
          let frame = try? JSONValueDecoder().decode(Frame.self, from: value)
    else {
      throw .protocolViolation("undecodable frame")
    }
    return frame
  }
}

extension Frame {
  public init(streamID: Int, opcode: Opcode, payload: some Encodable) {
    self.init(streamID: streamID, opcode: opcode, body: try! JSONValueEncoder().encode(payload))
  }

  public func payload<Payload: Decodable>(_ type: Payload.Type) throws(ChannelError) -> Payload {
    guard let payload = try? JSONValueDecoder().decode(type, from: body) else {
      throw .protocolViolation("malformed \(opcode.rawValue) body")
    }
    return payload
  }

  var requestID: Int? {
    guard case let .object(fields) = body, case let .integer(id)? = fields["id"] else { return nil }
    return id
  }
}
