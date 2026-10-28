#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Contract
import JSONValue

@Contract
public struct MachineChallengeOutput: Codable, Equatable, Sendable {
  public let challenge: String
}
