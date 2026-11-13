#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import LoopCore
import SessionDomain
@testable import SpaceCore
import Wuwei

extension SessionStore {
  func markInterrupted(_ id: SessionID) async throws {
    try await space.worker.call(SessionCell.ID(id.rawValue)) { try $0.interrupt() }
  }
}
