public struct CommandFailure: Error, CustomStringConvertible, Sendable {
  public let command: [String]
  public let status: Int32
  public let stderr: String

  public init(command: [String], status: Int32, stderr: String) {
    self.command = command; self.status = status; self.stderr = stderr
  }

  public var description: String { "\(self.command.joined(separator: " ")) exited \(self.status): \(self.stderr)" }
}
