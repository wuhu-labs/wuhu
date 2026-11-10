#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
@testable import SpaceCore

/// Session writes the cell makes, as fixtures: a test sets a session's state with them directly.
extension SessionStore {
  func markInterrupted(_ id: SessionID) async throws {
    try await rows { try $0.markInterrupted(id) }
  }
}
