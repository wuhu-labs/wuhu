#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum Assertion.VerifyingKey
import Crypto
import GroupContract
import struct MachineContract.MachineID
import MachinesContract
import SpaceIDs
import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID
import TenancyContract
import Wuwei

extension Machines {
  public func addMachineV2(name raw: String, group: GroupID = .shared, scope: ReachScope = .owner) async throws -> (machine: MachineRecord, token: MintedJoinToken) {
    guard let name = MachineName.normalized(raw) else { throw SpaceError.invalidMachineName(raw) }
    let now = date()
    let token = mintJoinToken(at: now)
    let machine = try await createMachine(name: name, group: group, scope: scope, at: now, credential: .token(hash: Self.tokenDigest(token.token), expiresAt: token.expiresAt))
    return (machine, token)
  }

  /// One-call enrollment for a machine whose key already exists on the caller's side (the Wuhu app): the machine is
  /// born with its key and named, and the optional device link follows.
  ///
  /// `enrolledBy`, when given, must own `device`; a device it does not own is reported as unknown. Replaying is
  /// idempotent: when `name` is the current name of a machine in `group` whose key is `pubkey` and was enrolled by the
  /// same person, the call returns that machine unchanged (re-applying the device link). Anything else holding the name
  /// is `machineNameTaken`; a concurrent twin may hear that once and replay on its retry. An unattributed enrollment
  /// (`enrolledBy` nil) never replays: there is no person to match.
  public func enrollMachineV2(
    name raw: String,
    group: GroupID,
    pubkey: String,
    device: String? = nil,
    enrolledBy: AccountID? = nil,
  ) async throws -> MachineRecord {
    guard let name = MachineName.normalized(raw) else { throw SpaceError.invalidMachineName(raw) }
    guard VerifyingKey(label: pubkey) != nil else { throw SpaceError.malformedPubkey(pubkey) }
    var linked: DeviceRecord?
    if let device {
      guard let row = await tenancy.device(device) else { throw SpaceError.unknownDevice(device) }
      if let enrolledBy, row.account != enrolledBy { throw SpaceError.unknownDevice(device) }
      linked = row
    }
    let machine: MachineRecord
    if let holder = directoryCell.row(pubkey: pubkey) {
      guard let enrolledBy, holder.enrolledBy == enrolledBy.rawValue, let named = try await self.machine(named: name),
            named.id.rawValue == holder.id, named.name == name, named.group == group
      else { throw SpaceError.alreadyExists(pubkey) }
      machine = named
    } else {
      machine = try await createMachine(name: name, group: group, scope: .owner, at: date(), credential: .key(pubkey, enrolledBy: enrolledBy))
    }
    if let linked, linked.machine != machine.id {
      _ = try await tenancy.annotateDevice(linked.id, machine.id)
    }
    return machine
  }

  /// The row comes first and the name after, so a crash between them leaves a nameless machine its owner can delete,
  /// never a name nothing can free.
  private func createMachine(name: String, group: GroupID, scope: ReachScope, at now: Date, credential: MachineCredential) async throws -> MachineRecord {
    let id = MachineID(rawValue: "mc_" + randomSuffix(MachineID.suffixLength))
    let cell = MachineCell.ID(id.rawValue)
    _ = try await worker.call(cell) { try $0.create(group: group, scope: scope, at: now, credential: credential) }
    do {
      try await tenancy.claimMachine(id, name)
    } catch {
      _ = try await worker.call(cell) { try $0.delete(in: group) }
      throw error
    }
    return MachineRecord(id: id, name: name, createdAt: now, group: group, scope: scope)
  }

  /// A box's enrollment with the token its machine was created or rotated with; the answer is the machine.
  func enrollMachineV2(token: JoinToken, pubkey: String) async throws -> MachineRecord {
    guard JoinToken.isValid(token.rawValue) else { throw JoinTokenRejected() }
    guard VerifyingKey(label: pubkey) != nil else { throw SpaceError.malformedPubkey(pubkey) }
    guard let id = directoryCell.machine(tokenHash: Self.tokenDigest(token)) else { throw JoinTokenRejected() }
    let now = date()
    guard try await worker.call(MachineCell.ID(id.rawValue), { try $0.enroll(tokenHash: Self.tokenDigest(token), pubkey: pubkey, at: now) }),
          let machine = try await machine(id)
    else { throw JoinTokenRejected() }
    return machine
  }

  /// Kick and re-invite: the key goes, its connections close, and the returned token enrolls the box's next key.
  func rotateMachine(_ id: MachineID) async throws -> MintedJoinToken {
    let token = mintJoinToken(at: date())
    _ = try await worker.call(MachineCell.ID(id.rawValue)) { try $0.rotate(tokenHash: Self.tokenDigest(token.token), expiresAt: token.expiresAt) }
    return token
  }

  /// The key and the pending token go and the connections close. With `pubkey` it is the machine's own revocation,
  /// refused (false) unless that is its key.
  public func revokeMachine(_ id: MachineID, presenting pubkey: String? = nil) async throws -> Bool {
    try await worker.call(MachineCell.ID(id.rawValue)) { try $0.revoke(presenting: pubkey) }
  }

  private func mintJoinToken(at now: Date) -> MintedJoinToken {
    MintedJoinToken(token: JoinToken(rawValue: JoinToken.prefix + randomSuffix(JoinToken.suffixLength)), expiresAt: now.addingTimeInterval(3600))
  }

  /// The space's credential digest, so a hash copied from a join token row stays the token's.
  static func tokenDigest(_ token: JoinToken) -> String {
    let digits = Array("0123456789abcdef")
    return String(SHA256.hash(data: Data(token.rawValue.utf8)).flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 0x0F)]] })
  }

  public func registerReleases(version: String, client: MachineReleaseClient) throws {
    worker.provide(client)
    try worker.create(MachineReleaseJob.singleton, params: .init())
    if MachineV2ReleaseVersion.isValid(version) { worker.send(.resolve(version), to: MachineReleaseJob.singleton) }
  }
}
