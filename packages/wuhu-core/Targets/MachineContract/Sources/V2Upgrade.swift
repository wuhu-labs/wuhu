import Contract
import JSONValue

/// One release archive (`.zip` on macOS, `.tar.gz` on Linux) holding a single `wuhu`; `sha256` digests the archive bytes.
@Contract
public struct MachineV2Artifact: Codable, Equatable, Sendable {
  public let platform: String
  public let url: String
  public let sha256: String
}

@Contract
public enum MachineV2UpgradeStatus: String, Codable, Equatable, Sendable {
  case ready
  case paused
  case unstamped
  case unpublished
  case unreachable
}

/// The agent version the server wants on a machine. Only `ready` may be installed, and only from the artifact for the machine's own platform.
@Contract
public struct MachineV2Upgrade: Codable, Equatable, Sendable {
  public let version: String?
  public let pinned: Bool
  public let status: MachineV2UpgradeStatus
  public let artifacts: [MachineV2Artifact]
}
