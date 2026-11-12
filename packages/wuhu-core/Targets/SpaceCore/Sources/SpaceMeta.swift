#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import GRDB
import Logging
import StructuredQueries

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
  static let memorySchema: Result<DatabaseQueue, any Error> = Result {
    let queue = try DatabaseQueue()
    try Migrations.apply(to: queue, log: Logger(label: "wuhu.migration") { _ in SwiftLogNoOpLogHandler() }, date: .constant(Date(timeIntervalSince1970: 0)))
    return queue
  }

  static func prepare(_ queue: any DatabaseWriter, identity: SpaceIdentity? = nil, log: Logger, date: DateGenerator) throws {
    try queue.read { db in
      if let identity, try db.tableExists("space_meta"),
         let actual = try String.fetchOne(db, sql: "SELECT space_id FROM space_meta WHERE id = 1"), actual != identity.rawValue
      {
        throw SpaceIdentityError.mismatch(expected: identity.rawValue, actual: actual)
      }
    }
    try Migrations.apply(to: queue, log: log, date: date)
    try queue.write { db in
      try seedIfAbsent(in: db, identity: identity)
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

  // Default ids use system entropy, never the injected RNG stream that belongs
  // to account/machine/token ids. Provisioners may supply their persisted id.
  static func seedIfAbsent(in db: Database, identity: SpaceIdentity?) throws {
    guard try Row.fetchOne(db, sql: "SELECT 1 FROM space_meta WHERE id = 1") == nil else { return }
    var generator = SystemRandomNumberGenerator()
    let id = identity?.rawValue ?? (SpaceIdentity.prefix + randomAlphanumericSuffix(SpaceIdentity.suffixLength, using: &generator))
    try db.execute(sql: "INSERT INTO space_meta (id, space_id) VALUES (1, ?)", arguments: [id])
  }
}

public struct DeploymentRecord: Hashable, Codable, Sendable {
  public enum Certificate: Hashable, Codable, Sendable {
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

@Table("space_deployment")
struct DeploymentRow {
  @Column(primaryKey: true) var id: Int64
  var origin: String?
  @Column("tls_fingerprint") var tlsFingerprint: String
}

@Table("space_deployment_certificate")
struct DeploymentCertificateRow {
  @Column(primaryKey: true) var id: Int64
  @Column("tls_fingerprint") var tlsFingerprint: String
  var generated: Bool
}

extension SpaceCell {
  /// Serve writes this at boot (origin exactly as passed via `--origin`, NULL when absent — the record never lies); offline verbs read it.
  ///
  /// The certificate kind lives in its own row, keyed by the fingerprint it describes: a server that predates it rewrites
  /// `space_deployment` alone, and the stale row then no longer matches, so the record reads as unknown.
  mutating func recordDeployment(_ record: DeploymentRecord) throws {
    try db.execute(DeploymentRow.insert {
      DeploymentRow(id: 1, origin: record.origin, tlsFingerprint: record.tlsFingerprint)
    } onConflict: {
      ($0.id)
    } doUpdate: {
      $0.origin = $1.origin
      $0.tlsFingerprint = $1.tlsFingerprint
    })
    try db.execute(DeploymentCertificateRow.delete())
    guard let certificate = record.certificate else { return }
    try db.execute(DeploymentCertificateRow.insert {
      DeploymentCertificateRow(id: 1, tlsFingerprint: record.tlsFingerprint, generated: certificate == .generated)
    })
  }

  func deployment() -> DeploymentRecord? {
    guard let row = db.rows(DeploymentRow.all).first else { return nil }
    let certificate = db.rows(DeploymentCertificateRow.where { $0.tlsFingerprint.eq(row.tlsFingerprint) }).first
    return DeploymentRecord(
      origin: row.origin, tlsFingerprint: row.tlsFingerprint, certificate: certificate.map { $0.generated ? .generated : .provided },
    )
  }
}

extension Space {
  public func recordDeployment(_ record: DeploymentRecord) async throws {
    try await worker.call(SpaceCell.ID("space")) { try $0.recordDeployment(record) }
  }

  public func deployment() async throws -> DeploymentRecord? {
    cell.deployment()
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

public enum SpaceIdentityError: Error, Equatable, Sendable {
  case invalid(String)
  case mismatch(expected: String, actual: String)
}
