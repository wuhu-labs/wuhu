import MachineChannel
import MachineContract
import Testing

@Suite
struct CodecTests {
  @Test func framesRoundTripThroughWireBytes() throws {
    let frames: [Frame] = [
      Frame(streamID: 0, opcode: .control, payload: ControlMessage.ping),
      Frame(streamID: 3, opcode: .output, payload: OutputChunk(id: execID(1), stream: .stderr, cursor: 42, data: Base64Data([1, 2, 3]))),
      Frame(streamID: 0, opcode: .vfsRequest, payload: VFSRequest(id: 9, op: .read(path: "/etc/hosts"))),
      Frame(streamID: 7, opcode: .execExit, payload: ExecExit(id: execID(2), cursor: 100, status: .signaled(signal: 9))),
    ]
    for frame in frames {
      #expect(try FrameCodec.decode(FrameCodec.encode(frame)) == frame)
    }
  }

  @Test func garbageBytesThrowProtocolViolation() {
    #expect(throws: ChannelError.self) {
      try FrameCodec.decode(Array("not json".utf8))
    }
    #expect(throws: ChannelError.self) {
      try FrameCodec.decode(Array("{\"streamID\": true}".utf8))
    }
  }

  @Test func typedPayloadDecodeChecksTheBodyShape() throws {
    let frame = Frame(streamID: 1, opcode: .ack, payload: Ack(id: execID(1), cursor: 5))
    #expect(try frame.payload(Ack.self) == Ack(id: execID(1), cursor: 5))
    #expect(throws: ChannelError.self) {
      try frame.payload(OutputChunk.self)
    }
  }
}
