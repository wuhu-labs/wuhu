import JSONValue
import SpaceContract
import Testing

@Suite
struct WmdWireTests {
  private let encoder = JSONValueEncoder()
  private let decoder = JSONValueDecoder()

  @Test func controlsEncodeTypeTagged() throws {
    let hello = WmdClientControl.hello(authorization: "Bearer x", group: nil, peer: "42", create: nil)
    #expect(try encoder.encode(hello) == .object(["type": "hello", "authorization": "Bearer x", "peer": "42"]))
    #expect(try decoder.decode(WmdClientControl.self, from: encoder.encode(hello)) == hello)
    let create = WmdClientControl.hello(authorization: nil, group: nil, peer: "42", create: true)
    #expect(try encoder.encode(create) == .object(["type": "hello", "peer": "42", "create": true]))
    let welcome = WmdServerControl.welcome(
      connection: "c1", name: "Ada", access: .write,
      peers: [WmdPeer(connection: "c0", peer: "7", name: "Bo", access: .read)], rev: nil,
    )
    #expect(try decoder.decode(WmdServerControl.self, from: encoder.encode(welcome)) == welcome)
    #expect(try encoder.encode(WmdServerControl.error(code: .readOnly, message: "m")) == .object([
      "type": "error", "code": "readOnly", "message": "m",
    ]))
  }

  @Test func framesRoundTripThroughTheirTag() throws {
    let frames: [WmdFrame] = [.sync(versionVector: [1, 2]), .update([3]), .presence([]), .synced(versionVector: [9])]
    for frame in frames {
      #expect(try WmdFrame(bytes: frame.bytes) == frame)
    }
    #expect(WmdFrame.update([5]).bytes == [0x02, 5])
    #expect(throws: WmdFrame.Malformed.self) { try WmdFrame(bytes: [0x09]) }
    #expect(throws: WmdFrame.Malformed.self) { try WmdFrame(bytes: []) }
  }
}
