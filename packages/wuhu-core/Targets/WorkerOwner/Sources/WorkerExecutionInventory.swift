#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum JSONValue.JSONValue
import struct LoopCore.SessionAssignmentInventory
import struct SessionDomain.SessionID
import struct WorkerProtocol.WorkerCallInventory

public struct WorkerExecutionInventory: Codable, Equatable, Sendable {
  public let assignments: [SessionAssignmentInventory]
  public let scripts: [String: SessionID]
  public let inferences: [SessionID: [UUID]]
  public let pendingOwnerCalls: [WorkerCallInventory]
}

public struct WorkerStreamInventory: Codable, Equatable, Sendable {
  public let id: UUID
  public let operation: String
  public let marker: JSONValue?
  public let revision: Int?
}
