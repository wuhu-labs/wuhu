#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import GRDBSQLite
import Logging
import StructuredQueries
import Wuwei

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
  private static let memorySchema: Result<SQLiteWriter, any Error> = Result {
    let writer = try SQLiteWriter(path: ":memory:", flags: WuweiDatabase.openFlags, pragmas: ["PRAGMA foreign_keys = ON", "PRAGMA busy_timeout = 0"])
    try writer.access { try Migrations.apply(handle: $0, log: Logger(label: "wuhu.migration") { _ in SwiftLogNoOpLogHandler() }, date: .constant(Date(timeIntervalSince1970: 0))) }
    return writer
  }

  static func cloneMemorySchema(to database: WuweiDatabase) throws {
    try memorySchema.get().access { source in
      try database.accessWriter { destination in
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
          throw SQLiteError(code: sqlite3_errcode(destination), message: String(cString: sqlite3_errmsg(destination)))
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
          throw SQLiteError(code: finish == SQLITE_OK ? step : finish, message: String(cString: sqlite3_errmsg(destination)))
        }
      }
    }
  }

  static func prepare(_ database: WuweiDatabase, identity: SpaceIdentity? = nil, log: Logger, date: DateGenerator) throws -> SpaceIdentity {
    try database.accessWriter { handle in
      let db = MigrationDB(handle: handle)
      if let identity, try db.tableExists("space_meta"),
         let actual = try db.string("SELECT space_id FROM space_meta WHERE id = 1"), actual != identity.rawValue
      {
        throw SpaceIdentityError.mismatch(expected: identity.rawValue, actual: actual)
      }
      try Migrations.apply(handle: handle, log: log, date: date)
      try db.inImmediateTransaction { try seedIfAbsent(in: db, identity: identity) }
      return SpaceIdentity(rawValue: try db.string("SELECT space_id FROM space_meta WHERE id = 1")!)
    }
  }

  static func seedIfAbsent(in db: MigrationDB, identity: SpaceIdentity?) throws {
    guard try db.row("SELECT 1 FROM space_meta WHERE id = 1") == nil else { return }
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
    identityCache
  }
}

public enum SpaceIdentityError: Error, Equatable, Sendable {
  case invalid(String)
  case mismatch(expected: String, actual: String)
}
