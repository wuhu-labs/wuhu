import Foundation
import GRDB

let personaSchemaSQL = """
CREATE TABLE IF NOT EXISTS "personas" (
  "name" TEXT NOT NULL PRIMARY KEY,
  "allocation" INTEGER NOT NULL UNIQUE,
  "pubkey" TEXT NOT NULL,
  "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
  "created_at" TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS "personas_by_account" ON "personas" ("account_id");
"""

public struct PersonaRecord: Equatable, Sendable {
  public let name: String
  public let key: String
  public let account: AccountID
}

extension Space {
  public func mintPersona(key: KeyRecord) async throws -> PersonaRecord {
    let created = SQLiteDateFormat.string(from: dateGen.now)
    let minted = Allocations.mintSecretCandidate(rng)
    let name = try await writer.write { db in
      try insertPersona(db, key: key, created: created, minted: minted)
    }
    return PersonaRecord(name: name, key: key.pubkey, account: key.account)
  }

  // Personas are account-interchangeable, so adoption converges every key of
  // one account onto the account's earliest draw; a per-key adoption would
  // fragment notification inboxes across a human's devices.
  public func adoptPersona(key: KeyRecord) async throws -> PersonaRecord {
    let created = SQLiteDateFormat.string(from: dateGen.now)
    let minted = Allocations.mintSecretCandidate(rng)
    let rng = rng
    return try await writer.write { db in
      if let existing = try firstPersona(db, account: key.account) { return existing }
      let name = try insertPersona(db, key: key, created: created, minted: minted)
      if try String.fetchOne(db, sql: "SELECT kind FROM accounts WHERE id = ?", arguments: [key.account.rawValue]) == "human" {
        _ = try Groups.ensurePersonalGroup(account: key.account, created: created, rng: rng, in: db)
      }
      return PersonaRecord(name: name, key: key.pubkey, account: key.account)
    }
  }

  public func persona(named name: String) async throws -> PersonaRecord? {
    try await writer.read { db in
      try Row.fetchOne(db, sql: "SELECT name, pubkey, account_id FROM personas WHERE name = ?", arguments: [name])
        .map(personaRecord)
    }
  }

  public func persona(account: AccountID) async throws -> PersonaRecord? {
    try await writer.read { db in
      try firstPersona(db, account: account)
    }
  }

  public func personas() async throws -> [PersonaRecord] {
    try await writer.read { db in
      try Row.fetchAll(db, sql: "SELECT name, pubkey, account_id FROM personas ORDER BY allocation")
        .map(personaRecord)
    }
  }
}

private func personaRecord(_ row: Row) -> PersonaRecord {
  PersonaRecord(
    name: row["name"],
    key: row["pubkey"],
    account: AccountID(rawValue: row["account_id"]),
  )
}

private func firstPersona(_ db: Database, account: AccountID) throws -> PersonaRecord? {
  try Row.fetchOne(
    db,
    sql: "SELECT name, pubkey, account_id FROM personas WHERE account_id = ? ORDER BY allocation LIMIT 1",
    arguments: [account.rawValue],
  ).map(personaRecord)
}

// A human's first persona takes the allocation its personal group was named after.
private func insertPersona(_ db: Database, key: KeyRecord, created: String, minted: [UInt8]) throws -> String {
  let (id, name) = try Groups.reservedPersona(of: key.account, in: db)
    ?? Allocations.draw(.persona, createdBy: key.pubkey, created: created, minted: minted, in: db)
  try db.execute(
    sql: "INSERT INTO personas (name, allocation, pubkey, account_id, created_at) VALUES (?, ?, ?, ?, ?)",
    arguments: [name, id, key.pubkey, key.account.rawValue, created],
  )
  return name
}
