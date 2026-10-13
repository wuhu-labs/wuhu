import Logging

public enum SpaceLogContext {
  @TaskLocal public static var spaceID: String?

  public static let metadataProvider = Logger.MetadataProvider {
    spaceID.map { ["space": .string($0)] } ?? [:]
  }
}
