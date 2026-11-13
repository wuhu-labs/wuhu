import Dependencies
import Foundation

public enum AllocationKind: String, Sendable {
  case persona
  case session
  case device
  case group
}

public struct Allocation: Equatable, Sendable {
  public let id: Int64
  public let name: String
  public let kind: AllocationKind
  public let createdBy: String
  public let createdAt: Date
}

enum Allocations {
  static func mintSecretCandidate(_ rng: WithRandomNumberGenerator) -> [UInt8] {
    rng { generator in (0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) } }
  }
}
