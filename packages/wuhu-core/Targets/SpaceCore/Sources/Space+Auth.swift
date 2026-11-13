import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID

extension Space {
  public func addAccount(kind: AccountKind, name: String?, admin: Bool = false, guest: Bool = false) async throws -> AccountRecord {
    if (admin || guest), kind != .human { throw SpaceError.notAPerson(name ?? kind.rawValue) }
    if admin, guest { throw SpaceError.notAPerson(name ?? kind.rawValue) }
    let id = AccountID(rawValue: AccountID.prefix + randomSuffix(AccountID.suffixLength))
    let createdAt = dateGen.now
    _ = try await worker.call(PersonCell.ID(id.rawValue)) { try $0.create(kind: kind, name: name, guest: guest, at: createdAt) }
    if admin { return try await setAdmin(id, admin: true) }
    return AccountRecord(id: id, kind: kind, name: name, isAdmin: false, guest: guest, createdAt: createdAt, removedAt: nil)
  }

  public func account(_ id: AccountID) async throws -> AccountRecord? { cell.account(id) }
  public func accounts() async throws -> [AccountRecord] { cell.accounts() }
  public func hasAdminAccount() async throws -> Bool { cell.hasAdminAccount() }

  public func setAdmin(_ id: AccountID, admin: Bool) async throws -> AccountRecord {
    guard let record = worker.cell(PersonCell.ID(id.rawValue)).account(), record.removedAt == nil else { throw SpaceError.notFound(id.rawValue) }
    if admin, record.kind != .human || record.guest { throw SpaceError.notAPerson(id.rawValue) }
    let stamp = SQLiteDateFormat.string(from: dateGen.now)
    _ = try await worker.call(GroupCell.ID(GroupID.settings.rawValue)) { try $0.setAdmin(id, admin: admin, at: stamp) }
    guard let record = cell.account(id) else { throw SpaceError.notFound(id.rawValue) }
    return record
  }

  public func removeAccount(_ id: AccountID) async throws -> (keys: Int, readSessions: Int) {
    _ = try await setAdmin(id, admin: false)
    let now = dateGen.now
    return try await worker.call(PersonCell.ID(id.rawValue)) { try $0.removeAccount(at: now) }
  }

  public func addKey(_ pubkey: String, account: AccountID, capabilities: Set<KeyCapability>, createdBy: AccountID?, expiresAt: Date?) async throws -> KeyRecord {
    let now = dateGen.now
    return try await worker.call(PersonCell.ID(account.rawValue)) { try $0.addKey(pubkey, capabilities: capabilities, createdBy: createdBy, at: now, expiresAt: expiresAt) }
  }

  public func keyRecord(pubkey: String) async throws -> KeyRecord? { cell.keyRecord(pubkey: pubkey) }
  public func keys(account: AccountID) async throws -> [KeyRecord] { worker.cell(PersonCell.ID(account.rawValue)).keys() }
  public func credential(pubkey: String) async throws -> KeyRecord? {
    guard let record = cell.keyRecord(pubkey: pubkey), Self.isLive(record.expiresAt, at: dateGen.now) else { return nil }
    return record
  }

  public func removeKey(pubkey: String) async throws {
    guard let key = cell.keyRecord(pubkey: pubkey) else { throw SpaceError.notFound(pubkey) }
    _ = try await worker.call(PersonCell.ID(key.account.rawValue)) { try $0.removeKey(pubkey) }
  }

  public func createReadSession(account: AccountID, group: GroupID, expiresAt: Date, supersedes: ReadSessionToken? = nil) async throws -> ReadSessionToken {
    let token = ReadSessionToken(rawValue: ReadSessionToken.prefix + randomSuffix(ReadSessionToken.suffixLength))
    let now = dateGen.now
    _ = try await worker.call(PersonCell.ID(account.rawValue)) { try $0.createReadSession(token, group: group, at: now, expiresAt: expiresAt, supersedes: supersedes) }
    return token
  }

  public func account(readSession: ReadSessionToken, in group: GroupID) async throws -> AccountID? {
    guard ReadSessionToken.isValid(readSession.rawValue), let row = cell.readSession(readSession), (row.group ?? GroupID.shared.rawValue) == group.rawValue,
          Self.isLive(try SQLiteDateFormat.date(from: row.expiresAt), at: dateGen.now) else { return nil }
    return AccountID(rawValue: row.accountID)
  }

  public func deleteReadSession(_ token: ReadSessionToken) async throws {
    guard let row = cell.readSession(token) else { return }
    _ = try await worker.call(PersonCell.ID(row.accountID)) { try $0.deleteReadSession(token) }
  }

  public func resetCredentials(account: AccountID) async throws -> (keys: Int, readSessions: Int) {
    return try await worker.call(PersonCell.ID(account.rawValue)) { try $0.resetCredentials() }
  }

  static func isLive(_ expiresAt: Date?, at now: Date) -> Bool {
    expiresAt.map { now < $0 } ?? true
  }

  static func stored(_ capabilities: Set<KeyCapability>) -> String {
    capabilities.map(\.rawValue).sorted().joined(separator: " ")
  }

  static func capabilitySet(_ stored: String) -> Set<KeyCapability>? {
    var capabilities: Set<KeyCapability> = []
    for token in stored.split(separator: " ") {
      guard let capability = KeyCapability(rawValue: String(token)) else { return nil }
      capabilities.insert(capability)
    }
    return capabilities
  }

  // Tokens are 32-character CSPRNG credentials, so a plain digest is a sound
  // verifier: there is no low-entropy preimage to grind, and nothing stored
  // can be replayed as the token.
  static func credentialDigest(_ raw: String) -> String {
    hexEncoded(SHA256.hash(data: Data(raw.utf8)))
  }
}
