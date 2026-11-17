#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GroupContract
import SpaceIDs
import struct SpaceIDs.AccountID
import struct SpaceIDs.GroupID
import StructuredQueries
import Wuwei
import WuweiQueries

/// A machine's one credential at birth: the join token its box enrolls with, or the key the app already made.
enum MachineCredential: Equatable {
  case token(hash: String, expiresAt: Date)
  case key(String, enrolledBy: AccountID?)
}

extension MachineCell {
  mutating func create(group: GroupID, scope: ReachScope, at now: Date, credential: MachineCredential) throws {
    let created = SQLiteDateFormat.string(from: now)
    var row = MachineRow(id: id.key, createdAt: created, grp: group.rawValue, scope: scope.rawValue)
    switch credential {
    case let .token(hash, expiresAt):
      row.tokenHash = hash; row.tokenExpiresAt = SQLiteDateFormat.string(from: expiresAt)
    case let .key(pubkey, enrolledBy):
      try requireFree(pubkey)
      row.pubkey = pubkey; row.enrolledAt = created; row.enrolledBy = enrolledBy?.rawValue
    }
    try db.execute(MachineRow.insert { row })
    try db.execute(MachineV2MemberRow.insert { MachineV2MemberRow(machineID: id.key, grp: group.rawValue, createdAt: created) })
  }

  /// The token's first use stores `pubkey`; until the token expires, the same token with the same key is the same yes,
  /// so a box may retry an answer it lost.
  mutating func enroll(tokenHash: String, pubkey: String, at now: Date) throws -> Bool {
    guard var row = db.rows(MachineRow.where { $0.id.eq(id.key) }).first, row.tokenHash == tokenHash,
          let expiresAt = row.tokenExpiresAt, try now < SQLiteDateFormat.date(from: expiresAt),
          !db.rows(MachineV2MemberRow.where { $0.machineID.eq(id.key) && $0.grp.eq(row.grp) }).isEmpty
    else { return false }
    if let held = row.pubkey { return held == pubkey }
    try requireFree(pubkey)
    row.pubkey = pubkey; row.enrolledAt = SQLiteDateFormat.string(from: now); row.enrolledBy = nil
    try db.execute(MachineRow.update(row))
    return true
  }

  /// Kick and re-invite: the key goes, `tokenHash` becomes the pending token, and the box's connections close.
  mutating func rotate(tokenHash: String, expiresAt: Date) throws {
    guard try reset(presenting: nil, token: (tokenHash, SQLiteDateFormat.string(from: expiresAt))) else { throw SpaceError.notFound(id.key) }
  }

  /// The key and the pending token go and the box's connections close, in one step; with `pubkey`, only while that is
  /// the machine's key, so a rotation lands wholly before (false) or wholly after it.
  mutating func revoke(presenting pubkey: String? = nil) throws -> Bool {
    try reset(presenting: pubkey, token: nil)
  }

  private func requireFree(_ pubkey: String) throws {
    guard db.rows(MachineRow.where { $0.pubkey.eq(pubkey) }).isEmpty else { throw SpaceError.alreadyExists(pubkey) }
  }

  private mutating func reset(presenting pubkey: String?, token: (hash: String, expiresAt: String)?) throws -> Bool {
    guard var row = db.rows(MachineRow.where { $0.id.eq(id.key) }).first else { return false }
    if let pubkey, row.pubkey != pubkey { return false }
    row.pubkey = nil; row.enrolledAt = nil; row.enrolledBy = nil
    row.tokenHash = token?.hash; row.tokenExpiresAt = token?.expiresAt
    try db.execute(MachineRow.update(row))
    for socket in ctx.sockets(of: BoxSocket.self) { socket.close() }
    for socket in ctx.sockets(of: FileBulk.self) { socket.close() }
    return true
  }
}
