import Foundation
import GRDB

let spaceMetaSchemaSQL = """
CREATE TABLE IF NOT EXISTS "space_meta" (
  "id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1),
  "space_id" TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS "space_deployment" (
  "id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1),
  "origin" TEXT,
  "tls_fingerprint" TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS "space_deployment_certificate" (
  "id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1),
  "tls_fingerprint" TEXT NOT NULL,
  "generated" INTEGER NOT NULL
);
"""

public struct SpaceIdentity: Hashable, Sendable {
  static let prefix: String = "spc_"
  static let suffixLength: Int = 32

  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static func isValid(_ candidate: String) -> Bool {
    hasPrefixedAlphanumericSuffix(candidate, prefix: prefix, count: suffixLength)
  }
}

enum SpaceMeta {
  /// Brings a file to this binary's schema. A file from before a required compaction is refused, never
  /// patched; a fresh one is born compacted.
  static func prepare(_ db: Database) throws {
    let fresh = try !db.tableExists("fs_heads")
    if !fresh { try requireCompaction("wuhu-45", in: db) }
    try db.execute(sql: spaceSchemaSQL)
    if fresh { try recordCompaction(Space.linksCompaction, in: db) }
    try seedIfAbsent(in: db)
  }

  static func requireCompaction(_ name: String, in db: Database) throws {
    guard try db.tableExists("schema_compactions"), try hasCompaction(name, in: db) else {
      throw SpaceError.needsMigration(name)
    }
  }

  static func hasCompaction(_ name: String, in db: Database) throws -> Bool {
    try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM schema_compactions WHERE name = ?)", arguments: [name]) ?? false
  }

  static func recordCompaction(_ name: String, in db: Database) throws {
    try db.execute(
      sql: "INSERT OR IGNORE INTO schema_compactions (name, applied_at) VALUES (?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
      arguments: [name],
    )
  }

  // The id is a durable read-back value, never predicted, so it draws from
  // system entropy — NOT the injected \.withRandomNumberGenerator, whose
  // deterministic-in-test stream belongs to account/machine/token ids and
  // must not be shifted by constructing a Space.
  //
  // Idempotent: a re-open must never overwrite the id an earlier open minted.
  static func seedIfAbsent(in db: Database) throws {
    guard try Row.fetchOne(db, sql: "SELECT 1 FROM space_meta WHERE id = 1") == nil else { return }
    var generator = SystemRandomNumberGenerator()
    let id = SpaceIdentity.prefix + randomAlphanumericSuffix(SpaceIdentity.suffixLength, using: &generator)
    try db.execute(sql: "INSERT INTO space_meta (id, space_id) VALUES (1, ?)", arguments: [id])
  }
}

public struct DeploymentRecord: Hashable, Sendable {
  public enum Certificate: Hashable, Sendable {
    /// The one serve generated into `<folder>/tls`.
    case generated
    /// `--cert`/`--key`, self-signed or not.
    case provided
  }

  public let origin: String?
  public let tlsFingerprint: String
  /// nil on a record written by a server that did not tell the two apart.
  public let certificate: Certificate?

  public init(origin: String?, tlsFingerprint: String, certificate: Certificate?) {
    self.origin = origin
    self.tlsFingerprint = tlsFingerprint
    self.certificate = certificate
  }

  /// The fingerprint an invite hands out for clients to pin. Only the generated certificate is pinned; any other,
  /// and one this record cannot prove was generated, is left to the client's system trust.
  public var pin: String? {
    certificate == .generated ? tlsFingerprint : nil
  }
}

extension Space {
  // Ownership rule: serve writes this at boot (origin exactly as passed via
  // --origin, NULL when absent — the record never lies); offline verbs read
  // it; live clients read GET /v1/server; nobody else writes. argv stays
  // authoritative at runtime.
  //
  // The certificate kind lives in its own row, keyed by the fingerprint it
  // describes: a server that predates it rewrites space_deployment alone, and
  // the stale row then no longer matches, so the record reads as unknown.
  public func recordDeployment(_ record: DeploymentRecord) async throws {
    try await writer.write { db in
      try db.execute(
        sql: "INSERT OR REPLACE INTO space_deployment (id, origin, tls_fingerprint) VALUES (1, ?, ?)",
        arguments: [record.origin, record.tlsFingerprint],
      )
      if let certificate = record.certificate {
        try db.execute(
          sql: "INSERT OR REPLACE INTO space_deployment_certificate (id, tls_fingerprint, generated) VALUES (1, ?, ?)",
          arguments: [record.tlsFingerprint, certificate == .generated],
        )
      } else {
        try db.execute(sql: "DELETE FROM space_deployment_certificate")
      }
    }
  }

  public func deployment() async throws -> DeploymentRecord? {
    try await writer.read { db in
      guard let row = try Row.fetchOne(db, sql: """
      SELECT d.origin, d.tls_fingerprint, c.generated FROM space_deployment d
      LEFT JOIN space_deployment_certificate c ON c.tls_fingerprint = d.tls_fingerprint
      WHERE d.id = 1
      """) else {
        return nil
      }
      let generated: Bool? = row["generated"]
      return DeploymentRecord(
        origin: row["origin"],
        tlsFingerprint: row["tls_fingerprint"],
        certificate: generated.map { $0 ? .generated : .provided },
      )
    }
  }

  public func identity() async throws -> SpaceIdentity {
    if let identityCache { return identityCache }
    let identity = try await writer.read { db in
      guard let row = try Row.fetchOne(db, sql: "SELECT space_id FROM space_meta WHERE id = 1") else {
        preconditionFailure("space_meta must be seeded by Space.open/inMemory before identity() is read")
      }
      return SpaceIdentity(rawValue: row["space_id"])
    }
    identityCache = identity
    return identity
  }
}
