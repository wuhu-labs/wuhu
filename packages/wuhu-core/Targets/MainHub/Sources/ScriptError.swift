public struct ScriptError: Error, CustomStringConvertible, Sendable {
  public var description: String

  public init(_ description: String) {
    self.description = description
  }
}
