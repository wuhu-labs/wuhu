import Contract
import JSONValue
import MachineContract
import Testing

@Contract private enum LegacyControl: Codable, Equatable, Sendable {
  case hello(protocolVersion: Int)
  case ping
  case error(error: MachineError)
}

private struct LegacyAck: Codable, Equatable {
  let id: ExecID
  let cursor: Int
}

private struct LegacyExit: Codable, Equatable {
  let id: ExecID
  let cursor: Int
  let status: MachineContract.ExitStatus
}

@Suite struct RetentionCompatibilityTests {
  @Test func oldPeersIgnoreTheAdditiveFields() throws {
    let encode = JSONValueEncoder()
    let decode = JSONValueDecoder()
    let id = ExecID(rawValue: "ex_12345678")
    let hello = try encode.encode(ControlMessage.hello(protocolVersion: 1, execs: [id]))
    #expect(try decode.decode(LegacyControl.self, from: hello) == .hello(protocolVersion: 1))
    let ack = try encode.encode(Ack(id: id, cursor: 42, terminal: true))
    #expect(try decode.decode(LegacyAck.self, from: ack) == LegacyAck(id: id, cursor: 42))
    let exit = try encode.encode(ExecExit(id: id, cursor: 42, status: .signaled(signal: 15), outputCut: true))
    #expect(try decode.decode(LegacyExit.self, from: exit) == LegacyExit(id: id, cursor: 42, status: .signaled(signal: 15)))
  }

  @Test func newPeersAcceptLegacyFramesWithoutOptingIntoRetirement() throws {
    let encode = JSONValueEncoder()
    let decode = JSONValueDecoder()
    let id = ExecID(rawValue: "ex_12345678")
    #expect(try decode.decode(ControlMessage.self, from: encode.encode(LegacyControl.hello(protocolVersion: 1))) == .hello(protocolVersion: 1))
    #expect(try decode.decode(Ack.self, from: encode.encode(LegacyAck(id: id, cursor: 42))).terminal == nil)
    #expect(try decode.decode(ExecExit.self, from: encode.encode(LegacyExit(id: id, cursor: 42, status: .exited(code: 0)))).outputCut == nil)
  }
}
