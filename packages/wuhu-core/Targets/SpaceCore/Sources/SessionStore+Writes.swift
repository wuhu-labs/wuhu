#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

extension SessionStore {
  public static let titleLimit: Int = SessionTitle.maximumCharacters

  // A root is level 1; a session at level depthLimit + 1 is refused.
  public static let depthLimit: Int = 16

  public static func usableTitle(_ title: String) throws(SessionStoreError) -> String {
    let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty, cleaned.count <= Self.titleLimit, !cleaned.contains(where: \.isNewline) else {
      throw .unusableTitle(title)
    }
    return cleaned
  }
}

extension Duration {
  var timeInterval: TimeInterval {
    let (seconds, attoseconds) = components
    return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
  }
}
