import Contract
import JSONValue

// A file a session's exec runs as a space script (`wuhu script`).
@Contract
public struct ScriptRunInput: Codable, Equatable, Sendable {
  public let source: String
  public let arguments: [String]
}

// What a script run says to its caller, in order, closed by `end` once the run
// has ended: a run that succeeded says `result` once and no `failure`. A stream
// that stops without `end` is a run that did not end.
@Contract
public enum ScriptOutput: Codable, Equatable, Sendable {
  case update(text: String)
  case result(text: String)
  case failure(message: String)
  case end
}
