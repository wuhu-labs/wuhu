#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum SessionLifecycle: Hashable, Sendable, Codable {
  case live
  case archived(graceExpiresAt: Date)
}
