public enum WuhuEnvironmentResolutionError: Error, Sendable, CustomStringConvertible {
  case unknownEnvironment(String)
  case unsupportedEnvironmentType(String)
  case missingSessionIDForFolderTemplate

  public var description: String {
    switch self {
    case let .unknownEnvironment(name):
      "Unknown environment: \(name)"
    case let .unsupportedEnvironmentType(type):
      "Unsupported environment type: \(type)"
    case .missingSessionIDForFolderTemplate:
      "folder-template requires sessionID"
    }
  }
}
