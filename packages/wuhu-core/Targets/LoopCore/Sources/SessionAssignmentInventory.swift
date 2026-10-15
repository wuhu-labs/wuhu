#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.SessionID

public struct SessionAssignmentInventory: Codable, Equatable, Sendable {
  public let session: SessionID
  public let passes: Set<UUID>
  public let effect: UUID?
  public let yielding: Bool
  public let archiveReservation: UUID?
}

extension SessionExecution {
  public func inventory() async -> [SessionAssignmentInventory] { await registry.inventory() }
}

extension SessionRegistry {
  func inventory() async -> [SessionAssignmentInventory] {
    let actors = Array(sessions.values)
    var inventory: [SessionAssignmentInventory] = []
    for actor in actors { inventory.append(await actor.inventory) }
    return inventory
  }
}
