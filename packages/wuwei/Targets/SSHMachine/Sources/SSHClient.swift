/// What the SSH jobs need from SSH: a connection to a host, named as in the ssh config, and commands run over it.
public struct SSHClient: Sendable {
  public var connect: @Sendable (_ host: String) async throws -> SSHConnection

  public init(connect: @escaping @Sendable (_ host: String) async throws -> SSHConnection) {
    self.connect = connect
  }
}

public struct SSHConnection: Sendable {
  /// Throws ``SSHFailure/lost`` when the connection broke, after which the command may or may not have run.
  public var run: @Sendable (_ command: String) async throws -> SSHOutput
  public var close: @Sendable () async -> Void

  public init(run: @escaping @Sendable (_ command: String) async throws -> SSHOutput, close: @escaping @Sendable () async -> Void) {
    self.run = run
    self.close = close
  }
}

public struct SSHOutput: Codable, Sendable, Equatable {
  public var status: Int32
  public var stdout: String
  public var stderr: String

  public init(status: Int32, stdout: String, stderr: String = "") {
    self.status = status
    self.stdout = stdout
    self.stderr = stderr
  }
}

public enum SSHFailure: Error {
  case unreachable(String)
  case lost(String)
}

/// How a command ended, as its caller learns it.
public enum SSHReply: Codable, Sendable, Equatable {
  case output(SSHOutput)
  /// The command certainly did not run.
  case unreachable(String)
  /// The command may or may not have run: the connection broke, or the call timed out.
  case unknown(String)
}
