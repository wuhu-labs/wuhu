// Server memory the engine's own memory limit never sees. This caps
// everything one execution holds there: every unread fetched body, the output
// window of every machine process and the output budget of every running
// machine exec; a query result, read whole before it reaches the engine, and
// the query tool's one result must fit in what is left.
public let scriptBufferBytes = 64 << 20

public struct ScriptError: Error, CustomStringConvertible, Sendable {
  public var description: String

  public init(_ description: String) {
    self.description = description
  }
}
