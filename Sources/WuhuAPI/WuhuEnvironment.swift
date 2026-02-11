import Foundation

public enum WuhuEnvironmentType: String, Sendable, Codable, Hashable {
  case local
  case folderTemplate = "folder-template"
}

/// A snapshot of an environment definition persisted with a session.
///
/// The server resolves `name` to a concrete definition from config at session creation time and
/// stores this snapshot so that sessions remain reproducible even if the on-disk config changes.
public struct WuhuEnvironment: Sendable, Hashable, Codable {
  public var name: String
  public var type: WuhuEnvironmentType
  /// Absolute path used as the working directory for tools (session `cwd`).
  public var path: String
  /// For `folder-template` environments, the absolute path to the template folder used to create `path`.
  public var templatePath: String?
  /// For `folder-template` environments, an optional startup script executed in the copied workspace.
  public var startupScript: String?

  public init(
    name: String,
    type: WuhuEnvironmentType,
    path: String,
    templatePath: String? = nil,
    startupScript: String? = nil,
  ) {
    self.name = name
    self.type = type
    self.path = path
    self.templatePath = templatePath
    self.startupScript = startupScript
  }
}
