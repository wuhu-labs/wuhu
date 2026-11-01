import JSONValue
import SpaceContract
import Testing

@Suite
struct LiveWireTests {
  private let encoder = JSONValueEncoder()
  private let decoder = JSONValueDecoder()

  @Test func controlsEncodeTypeTagged() throws {
    let hello = LiveClientControl.hello(authorization: "Bearer x", group: nil, peer: "42", create: nil)
    #expect(try encoder.encode(hello) == .object(["type": "hello", "authorization": "Bearer x", "peer": "42"]))
    #expect(try decoder.decode(LiveClientControl.self, from: encoder.encode(hello)) == hello)
    let create = LiveClientControl.hello(authorization: nil, group: nil, peer: "42", create: true)
    #expect(try encoder.encode(create) == .object(["type": "hello", "peer": "42", "create": true]))
    let welcome = LiveServerControl.welcome(
      connection: "c1", name: "Ada", access: .write,
      peers: [LivePeer(connection: "c0", peer: "7", name: "Bo", access: .read)], rev: nil,
    )
    #expect(try decoder.decode(LiveServerControl.self, from: encoder.encode(welcome)) == welcome)
    #expect(try encoder.encode(LiveServerControl.error(code: .readOnly, message: "m")) == .object([
      "type": "error", "code": "readOnly", "message": "m",
    ]))
  }

  @Test func framesRoundTripThroughTheirTag() throws {
    let frames: [LiveFrame] = [.sync(versionVector: [1, 2]), .update([3]), .presence([]), .synced(versionVector: [9])]
    for frame in frames {
      #expect(try LiveFrame(bytes: frame.bytes) == frame)
    }
    #expect(LiveFrame.update([5]).bytes == [0x02, 5])
    #expect(throws: LiveFrame.Malformed.self) { try LiveFrame(bytes: [0x09]) }
    #expect(throws: LiveFrame.Malformed.self) { try LiveFrame(bytes: []) }
  }
}
