import struct MachineContract.MachineID
import struct SpaceIDs.AccountID

#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum DeviceKind: String, Hashable, Sendable, CaseIterable {
  case phone
  case pad
  case mac
  case vision
  case web
}

public struct DeviceRecord: Equatable, Sendable {
  public let id: String
  public let account: AccountID
  public let pubkey: String
  public let installation: String
  public let kind: DeviceKind
  public let name: String
  public let machine: MachineID?
  public let createdAt: Date
  public let lastSeenAt: Date

  public init(id: String, account: AccountID, pubkey: String, installation: String, kind: DeviceKind, name: String, machine: MachineID?, createdAt: Date, lastSeenAt: Date) {
    self.id = id; self.account = account; self.pubkey = pubkey; self.installation = installation; self.kind = kind
    self.name = name; self.machine = machine; self.createdAt = createdAt; self.lastSeenAt = lastSeenAt
  }
}
