import Foundation

public enum WuhuEnvironmentType: String, Sendable, Codable, Hashable {
  case local
  case folderTemplate = "folder-template"
}

/// Canonical environment definition stored in the server database.
///
/// Sessions store an immutable `WuhuEnvironment` snapshot at creation time so they remain reproducible even if
/// the canonical definition changes later.
public struct WuhuEnvironmentDefinition: Sendable, Hashable, Codable, Identifiable {
  /// UUID (lowercased) as a string.
  public var id: String
  public var name: String
  public var type: WuhuEnvironmentType
  /// For `local`, the working directory path. For `folder-template`, the workspaces root directory.
  public var path: String
  /// For `folder-template`, the template folder path. Nil for `local`.
  public var templatePath: String?
  /// For `folder-template`, an optional startup script executed in the copied workspace.
  public var startupScript: String?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: String,
    name: String,
    type: WuhuEnvironmentType,
    path: String,
    templatePath: String? = nil,
    startupScript: String? = nil,
    createdAt: Date,
    updatedAt: Date,
  ) {
    self.id = id
    self.name = name
    self.type = type
    self.path = path
    self.templatePath = templatePath
    self.startupScript = startupScript
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct WuhuCreateEnvironmentRequest: Sendable, Hashable, Codable {
  public var name: String
  public var type: WuhuEnvironmentType
  public var path: String
  public var templatePath: String?
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

public struct WuhuUpdateEnvironmentRequest: Sendable, Hashable, Codable {
  public var name: String?
  public var type: WuhuEnvironmentType?
  public var path: String?
  /// Nil means "not provided"; `.some(nil)` means "explicitly clear".
  public var templatePath: String??
  /// Nil means "not provided"; `.some(nil)` means "explicitly clear".
  public var startupScript: String??

  public init(
    name: String? = nil,
    type: WuhuEnvironmentType? = nil,
    path: String? = nil,
    templatePath: String?? = nil,
    startupScript: String?? = nil,
  ) {
    self.name = name
    self.type = type
    self.path = path
    self.templatePath = templatePath
    self.startupScript = startupScript
  }
}

/// A snapshot of an environment definition persisted with a session.
///
/// The server resolves an environment identifier to a canonical definition from SQLite at session creation time,
/// and stores this snapshot so that sessions remain reproducible even if the canonical definition changes.
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
