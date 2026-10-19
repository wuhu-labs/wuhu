public struct ScriptIdentityUnavailable: Error, Sendable {
  public let message: String
  public let code: String

  public init(message: String, code: String = "fetchIdentityUnavailable") {
    self.message = message
    self.code = code
  }
}
