import Crypto
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.MachineID
@testable import SpaceCore

/// A machine at a chosen id, with a live exec key — the id the test's own box socket addresses.
func seedBoxKey(space: Space, machine: String) async throws -> String {
  @Dependency(\.date) var date
  let pubkey = Curve25519.Signing.PrivateKey().pubkeyLabel
  let id = MachineID(rawValue: machine)
  if let record = try await space.machine(id) {
    _ = try await space.addKey(pubkey, account: record.account, capabilities: [.execMachine], createdBy: nil, expiresAt: nil)
    return pubkey
  }
  let account = AccountID(rawValue: "ac_" + UUID().uuidString.prefix(8).lowercased())
  let claim = MachineClaim(
    id: id, account: account, name: machine, group: .shared, scope: .owner, created: SQLiteDateFormat.string(from: date.now),
  )
  _ = try await space.worker.call(PersonCell.ID(account.rawValue)) { try $0.machineAccount(claim) }
  _ = try await space.worker.call(MachineCell.ID(machine)) { try $0.create(claim) }
  _ = try await space.addKey(pubkey, account: account, capabilities: [.execMachine], createdBy: nil, expiresAt: nil)
  return pubkey
}
