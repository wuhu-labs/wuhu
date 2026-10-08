import Contract
import JSONValue

@Contract
public enum Opcode: String, Codable, Equatable, Sendable {
  case control
  case execStart = "exec-start"
  case stdin
  case stdinEof = "stdin-eof"
  case output
  case execExit = "exec-exit"
  case ack
  case kill
  case vfsRequest = "vfs-request"
  case vfsResponse = "vfs-response"
  case searchRequest = "search-request"
  case searchResponse = "search-response"
}

@Contract
public struct Frame: Codable, Equatable, Sendable {
  public let streamID: Int
  public let opcode: Opcode
  public let body: JSONValue
}

@Contract
public enum ControlMessage: Codable, Equatable, Sendable {
  case hello(protocolVersion: Int, execs: [ExecID]? = nil)
  case ping
  case error(error: MachineError)
}
