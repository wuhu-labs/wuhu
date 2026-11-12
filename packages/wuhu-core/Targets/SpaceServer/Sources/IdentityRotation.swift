#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct IdentityKeySchedule: Codable, Equatable, Sendable {
  var currentKey: Data
  var rotatedAt: Date
  var nextKey: Data?
  var overlapBeganAt: Date?
  var switchedAt: Date?

  var signingWithNext: Bool { switchedAt != nil }

  func validate() throws {
    _ = try ServerIdentity(rawKey: currentKey)
    if let nextKey {
      let next = try ServerIdentity(rawKey: nextKey)
      guard next.kid != (try ServerIdentity(rawKey: currentKey)).kid,
            !signingWithNext || overlapBeganAt != nil
      else { throw IdentityError.keyUnavailable }
    } else if overlapBeganAt != nil || signingWithNext { throw IdentityError.keyUnavailable }
  }
}
