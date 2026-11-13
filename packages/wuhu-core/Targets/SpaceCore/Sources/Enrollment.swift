#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum Assertion.VerifyingKey
import struct MachineContract.MachineID
import struct SpaceContract.GroupID
import StructuredQueries

public struct JoinToken: Hashable, Sendable {
  static let prefix: String = "jt_"
  static let suffixLength: Int = 32

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func isValid(_ candidate: String) -> Bool {
    hasPrefixedAlphanumericSuffix(candidate, prefix: prefix, count: suffixLength)
  }
}

public struct JoinTokenRejected: Error, Equatable, Sendable {}

public struct MintedJoinToken: Equatable, Sendable {
  public let token: JoinToken
  public let expiresAt: Date
}

extension Space {
  public func addMachineV2(name: String, group: GroupID = .shared, scope: ReachScope = .owner) async throws -> (machine: MachineRecord, token: MintedJoinToken) {
    guard let name = MachineName.normalized(name) else { throw SpaceError.invalidMachineName(name) }
    let id = MachineID(rawValue: "mc_" + randomSuffix(MachineID.suffixLength))
    let account = AccountID(rawValue: AccountID.prefix + randomSuffix(AccountID.suffixLength))
    let token = JoinToken(rawValue: JoinToken.prefix + randomSuffix(JoinToken.suffixLength))
    let createdAt = dateGen.now
    let expiresAt = createdAt.addingTimeInterval(3600)
    let claim = MachineClaim(
      id: id, account: account, name: name, group: group, scope: scope, created: SQLiteDateFormat.string(from: createdAt),
    )
    _ = try await worker.call(SpaceCell.ID("space")) { try $0.claimMachine(claim) }
    _ = try await worker.call(PersonCell.ID(account.rawValue)) { try $0.machineAccount(claim) }
    _ = try await worker.call(MachineCell.ID(id.rawValue)) { try $0.create(claim) }
    _ = try await worker.call(PersonCell.ID(account.rawValue)) {
      try $0.mintJoinToken(token, capabilities: [.execMachine], createdBy: nil, at: createdAt, expiresAt: expiresAt)
    }
    return (MachineRecord(id: id, account: account, name: name, createdAt: createdAt, group: group, scope: scope), MintedJoinToken(token: token, expiresAt: expiresAt))
  }

  /// One-call enrollment for a machine whose key already exists on the caller's side (the Wuhu app): the name is
  /// claimed, then the machine's account, its row, its live key and the optional device link follow.
  ///
  /// `enrolledBy`, when given, must own `device`; a device it does not own is reported as unknown.
  ///
  /// Replaying is idempotent: when `name` is the current name of a v2 machine in `group` whose live exec-machine key
  /// is `pubkey` and was enrolled by the same person, the call returns that machine and key unchanged (re-applying the
  /// device link). Anything else holding the name is `machineNameTaken`; a concurrent twin may hear that once and
  /// replay on its retry. An unattributed enrollment (`enrolledBy` nil) never replays: there is no
  /// person to match.
  public func enrollMachineV2(
    name raw: String,
    group: GroupID,
    pubkey: String,
    device: String? = nil,
    enrolledBy: AccountID? = nil,
  ) async throws -> MachineV2Enrollment {
    guard let name = MachineName.normalized(raw) else { throw SpaceError.invalidMachineName(raw) }
    guard VerifyingKey(label: pubkey) != nil else { throw SpaceError.malformedPubkey(pubkey) }
    let now = dateGen.now
    var linked: DeviceRecord?
    if let device {
      guard let row = cell.device(id: device), enrolledBy == nil || row.account == enrolledBy else { throw SpaceError.unknownDevice(device) }
      linked = row
    }
    if let replayed = try replayedEnrollment(name: name, group: group, pubkey: pubkey, enrolledBy: enrolledBy, at: now) {
      if let linked, linked.machine != replayed.machine.id {
        _ = try await worker.call(PersonCell.ID(linked.account.rawValue)) { try $0.annotateDevice(linked.id, name: nil, machine: replayed.machine.id) }
      }
      return replayed
    }
    guard cell.keyRecord(pubkey: pubkey) == nil else { throw SpaceError.alreadyExists(pubkey) }
    let id = MachineID(rawValue: "mc_" + randomSuffix(MachineID.suffixLength))
    let account = AccountID(rawValue: AccountID.prefix + randomSuffix(AccountID.suffixLength))
    let claim = MachineClaim(
      id: id, account: account, name: name, group: group, scope: .owner, created: SQLiteDateFormat.string(from: now),
    )
    _ = try await worker.call(SpaceCell.ID("space")) { try $0.claimMachine(claim) }
    _ = try await worker.call(PersonCell.ID(account.rawValue)) { try $0.machineAccount(claim) }
    _ = try await worker.call(MachineCell.ID(id.rawValue)) { try $0.create(claim) }
    let key = try await worker.call(PersonCell.ID(account.rawValue)) {
      try $0.addKey(pubkey, capabilities: [.execMachine], createdBy: enrolledBy, at: now, expiresAt: nil)
    }
    if let linked {
      _ = try await worker.call(PersonCell.ID(linked.account.rawValue)) { try $0.annotateDevice(linked.id, name: nil, machine: id) }
    }
    return MachineV2Enrollment(
      machine: MachineRecord(id: id, account: account, name: name, createdAt: now, group: group, scope: .owner), key: key,
    )
  }

  private func replayedEnrollment(name: String, group: GroupID, pubkey: String, enrolledBy: AccountID?, at now: Date) throws -> MachineV2Enrollment? {
    guard let enrolledBy, let machine = cell.machine(named: name), machine.name == name, machine.group == group,
          cell.isMachineV2Account(machine.account),
          let key = cell.keyRecord(pubkey: pubkey), key.account == machine.account,
          Self.isLive(key.expiresAt, at: now), key.capabilities.contains(.execMachine), key.createdBy == enrolledBy
    else { return nil }
    return MachineV2Enrollment(machine: machine, key: key)
  }

  /// A machine's own revocation. One step checks that `pubkey` is a live exec-machine key of `machine`'s account and
  /// purges every credential of that account, so a rotation can only land wholly before (the key is dead: false) or
  /// wholly after it. The machine row stays.
  public func revokeMachine(_ machine: MachineID, presenting pubkey: String) async throws -> Bool {
    guard let record = worker.cell(MachineCell.ID(machine.rawValue)).record() else { return false }
    let now = dateGen.now
    return try await worker.call(PersonCell.ID(record.account.rawValue)) {
      try $0.revoke(machine: machine, presenting: pubkey, at: now)
    }
  }

  public func mintJoinToken(
    account: AccountID,
    capabilities: Set<KeyCapability>,
    createdBy: AccountID?,
    lifetime: TimeInterval,
  ) async throws -> MintedJoinToken {
    precondition(!capabilities.isEmpty, "a join token needs at least one capability")
    precondition(lifetime > 0, "a join token needs a positive lifetime")
    let token = JoinToken(rawValue: JoinToken.prefix + randomSuffix(JoinToken.suffixLength))
    let createdAt = dateGen.now
    let expiresAt = createdAt.addingTimeInterval(lifetime)
    _ = try await worker.call(PersonCell.ID(account.rawValue)) { try $0.mintJoinToken(token, capabilities: capabilities, createdBy: createdBy, at: createdAt, expiresAt: expiresAt) }
    return MintedJoinToken(token: token, expiresAt: expiresAt)
  }

  /// consume authenticates by the token itself: it must stay reachable without any prior credential, because the key
  /// it enrolls does not exist yet.
  public func consumeJoinToken(_ token: JoinToken, pubkey: String) async throws -> KeyRecord {
    try await consumeJoinToken(token, pubkey: pubkey, machineV2: false)
  }

  public func consumeMachineV2JoinToken(_ token: JoinToken, pubkey: String) async throws -> KeyRecord {
    try await consumeJoinToken(token, pubkey: pubkey, machineV2: true)
  }

  private func consumeJoinToken(_ token: JoinToken, pubkey: String, machineV2: Bool) async throws -> KeyRecord {
    guard JoinToken.isValid(token.rawValue) else { throw JoinTokenRejected() }
    let now = dateGen.now
    let hash = Self.credentialDigest(token.rawValue)
    guard let row = cell.joinToken(hash) else {
      // Already consumed: a machine's token replays to the key it enrolled, while that key lives; a person's wrote no
      // receipt and is refused.
      guard let receipt = cell.receipt(hash), receipt.pubkey == pubkey,
            Self.isLive(try SQLiteDateFormat.date(from: receipt.expiresAt), at: now),
            let key = cell.keyRecord(pubkey: pubkey), Self.isLive(key.expiresAt, at: now),
            !machineV2 || cell.isMachineV2Account(key.account)
      else { throw JoinTokenRejected() }
      return key
    }
    if machineV2, !cell.isMachineV2Account(AccountID(rawValue: row.accountID)) { throw JoinTokenRejected() }
    return try await worker.call(PersonCell.ID(row.accountID)) { try $0.consumeJoinToken(token, pubkey: pubkey, at: now) }
  }

  // The gate runs before the claiming step, so a refused revoke leaves the invite alive instead of burning it on the
  // way to the refusal.
  public func revokeJoinToken(
    _ token: JoinToken,
    revocableBy allows: @escaping @Sendable (AccountID) -> Bool,
  ) async throws -> AccountID? {
    guard JoinToken.isValid(token.rawValue) else { return nil }
    let now = dateGen.now
    let hash = Self.credentialDigest(token.rawValue)
    guard let row = cell.joinToken(hash), Self.isLive(try SQLiteDateFormat.date(from: row.expiresAt), at: now) else { return nil }
    let account = AccountID(rawValue: row.accountID)
    guard allows(account) else { throw JoinTokenRevocationRefused(account: account) }
    return try await worker.call(PersonCell.ID(row.accountID)) { try $0.revokeJoinToken(token, at: now) }
  }
}

public struct MachineV2Enrollment: Equatable, Sendable {
  public let machine: MachineRecord
  public let key: KeyRecord
}

public struct JoinTokenRevocationRefused: Error, Equatable, Sendable {
  public let account: AccountID
}

@Table("join_tokens")
struct EnrollmentTokenRow {
  @Column("token_hash", primaryKey: true) var tokenHash: String
  @Column("account_id") var accountID: String
  var capabilities: String
  @Column("created_by") var createdBy: String?
  @Column("created_at") var createdAt: String
  @Column("expires_at") var expiresAt: String
  var grp: String
  var owner: String
}
