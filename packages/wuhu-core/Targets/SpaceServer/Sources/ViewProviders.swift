#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct ViewProviders: Sendable {
  public let files: [String: Data]

  public init(files: [String: Data]) {
    self.files = files
  }

  #if WUHU_EMBEDDED
    public static let embedded: ViewProviders? = ViewProviders(files: Dictionary(
      uniqueKeysWithValues: EmbeddedViewProviders.files.map { file in
        (file.path.joined(separator: "/"), Data(EmbeddedViewProviders.bytes(for: file)))
      },
    ))
  #else
    public static let embedded: ViewProviders? = nil
  #endif
}
