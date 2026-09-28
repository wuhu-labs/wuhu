import Dependencies
import Foundation
import GRDB

let allocationSchemaSQL = """
CREATE TABLE IF NOT EXISTS "allocations" (
  "id" INTEGER PRIMARY KEY AUTOINCREMENT,
  "kind" TEXT NOT NULL,
  "created_by" TEXT NOT NULL,
  "created_at" TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS "allocation_freeze" (
  "id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1),
  "vocab_sha256" TEXT NOT NULL,
  "secret" BLOB NOT NULL
);
"""

public enum AllocationKind: String, Sendable {
  case persona
  case session
  case device
  case group
}

public struct Allocation: Equatable, Sendable {
  public let id: Int64
  public let name: String
  public let kind: AllocationKind
  public let createdBy: String
  public let createdAt: Date
}

enum Allocations {
  static func draw(
    _ kind: AllocationKind,
    createdBy: String,
    created: String,
    minted: [UInt8],
    in db: Database,
  ) throws -> (id: Int64, name: String) {
    let secret = try frozenSecret(db, minting: minted)
    try db.execute(
      sql: "INSERT INTO allocations (kind, created_by, created_at) VALUES (?, ?, ?)",
      arguments: [kind.rawValue, createdBy, created],
    )
    let id = db.lastInsertedRowID
    return (id, AllocationNames.name(for: id, words: AllocationVocabulary.words, secret: secret))
  }

  static func name(of id: Int64, in db: Database) throws -> String? {
    guard let secret = try Data.fetchOne(db, sql: "SELECT secret FROM allocation_freeze WHERE id = 1") else { return nil }
    return AllocationNames.name(for: id, words: AllocationVocabulary.words, secret: Array(secret))
  }

  // A candidate is only consumed by the first draw of a space, so later draws leave the generator alone.
  static func mintSecretCandidateIfUnfrozen(_ rng: WithRandomNumberGenerator, in db: Database) throws -> [UInt8] {
    try Row.fetchOne(db, sql: "SELECT 1 FROM allocation_freeze WHERE id = 1") == nil ? mintSecretCandidate(rng) : []
  }

  static func mintSecretCandidate(_ rng: WithRandomNumberGenerator) -> [UInt8] {
    rng { generator in (0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) } }
  }

  private static func frozenSecret(_ db: Database, minting secret: [UInt8]) throws -> [UInt8] {
    if let row = try Row.fetchOne(db, sql: "SELECT vocab_sha256, secret FROM allocation_freeze WHERE id = 1") {
      let frozen: String = row["vocab_sha256"]
      guard frozen == AllocationVocabulary.digest else {
        throw SpaceError.vocabularyFrozen(frozen)
      }
      return Array(row["secret"] as Data)
    }
    try db.execute(
      sql: "INSERT INTO allocation_freeze (id, vocab_sha256, secret) VALUES (1, ?, ?)",
      arguments: [AllocationVocabulary.digest, Data(secret)],
    )
    return secret
  }
}

extension Space {
  public func allocate(_ kind: AllocationKind, createdBy: String) async throws -> Allocation {
    let createdAt = dateGen.now
    let created = SQLiteDateFormat.string(from: createdAt)
    let minted = Allocations.mintSecretCandidate(rng)
    let (id, name) = try await writer.write { db in
      try Allocations.draw(kind, createdBy: createdBy, created: created, minted: minted, in: db)
    }
    return Allocation(id: id, name: name, kind: kind, createdBy: createdBy, createdAt: createdAt)
  }
}
