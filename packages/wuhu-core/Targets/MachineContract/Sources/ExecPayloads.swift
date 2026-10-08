import Contract
import JSONValue

public enum ExecDefaults {
  public static let window: Int = 4 * 1024 * 1024
}

/// The environment names the server owns in a session's exec. The server strips
/// them from a caller's `env` and `secrets`; the agent sets them from
/// `ExecStart.session`. `identity` is the CLI's opt-in, which nobody sets for it.
public enum SessionExecEnvironment {
  public static let exec: String = "WUHU_EXEC"
  public static let token: String = "WUHU_TOKEN"
  public static let spaceURL: String = "WUHU_SPACE_URL"
  public static let identity: String = "WUHU_IDENTITY"
  public static let group: String = "WUHU_GROUP"

  public static let reserved: Set<String> = [exec, token, spaceURL]
}

/// The credential a session's exec runs with: a token that acts as the session
/// while the exec lives, and the space it is good for.
@Contract
public struct ExecSessionCredential: Codable, Equatable, Sendable {
  public let token: String
  public let spaceURL: String
}

@Contract
public struct ExecStart: Codable, Equatable, Sendable {
  public let id: ExecID
  public let cwd: String
  public let command: [String]
  public let env: StringMap?
  public let secrets: StringMap?
  /// `ENV_NAME → value`, the server's resolution of `secrets` in the machine's
  /// group; sent only to an agent that announced `MachineConnect.groupSecrets`.
  public let secretValues: StringMap?
  public let window: Int?
  public let maxOutput: Int?
  public let timeout: Double?
  public let session: ExecSessionCredential?
}

@Contract
public struct StdinChunk: Codable, Equatable, Sendable {
  public let id: ExecID
  public let cursor: Int
  public let data: Base64Data
}

@Contract
public struct StdinEOF: Codable, Equatable, Sendable {
  public let id: ExecID
  public let cursor: Int
}

@Contract
public enum ExecOutputStream: String, Codable, Equatable, Sendable {
  case stdout
  case stderr
}

@Contract
public struct OutputChunk: Codable, Equatable, Sendable {
  public let id: ExecID
  public let stream: ExecOutputStream
  public let cursor: Int
  public let data: Base64Data
}

@Contract
public enum ExitStatus: Codable, Equatable, Sendable {
  case exited(code: Int)
  case signaled(signal: Int)
}

@Contract
public struct ExecExit: Codable, Equatable, Sendable {
  public let id: ExecID
  public let cursor: Int
  public let status: ExitStatus
  public let outputCut: Bool?
}

@Contract
public struct Ack: Codable, Equatable, Sendable {
  public let id: ExecID
  public let cursor: Int
  public let terminal: Bool?
}

@Contract
public struct Kill: Codable, Equatable, Sendable {
  public let id: ExecID
}

@Contract
public enum ExecEvent: Codable, Equatable, Sendable {
  case output(stream: ExecOutputStream, cursor: Int, data: Base64Data)
  case exit(status: ExitStatus)
  case truncated(limit: Int)
  case failed(error: MachineError)
}
