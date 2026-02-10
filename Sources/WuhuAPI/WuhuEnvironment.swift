import Foundation

public enum WuhuEnvironmentType: String, Sendable, Codable, Hashable {
  case local
}

/// A snapshot of an environment definition persisted with a session.
///
/// The server resolves `name` to a concrete definition from config at session creation time and
/// stores this snapshot so that sessions remain reproducible even if the on-disk config changes.
public struct WuhuEnvironment: Sendable, Hashable, Codable {
  public var name: String
  public var type: WuhuEnvironmentType
  /// Absolute path for `local` environments.
  public var path: String

  public init(name: String, type: WuhuEnvironmentType, path: String) {
    self.name = name
    self.type = type
    self.path = path
  }
}
