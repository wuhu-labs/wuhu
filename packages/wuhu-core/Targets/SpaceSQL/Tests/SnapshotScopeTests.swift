#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
@testable import SpaceSQL
import StructuredQueries
import Testing

@Table("private_auth")
private struct Authorization {
  let allowed: Bool
}

@Suite struct SnapshotScopeTests {
  @Test func resolverAndCallerShareASnapshotAndTrustedReadsDoNotGrantCallerAccess() async throws {
    let file = try Fixture()
    let writer = try DatabaseQueue(path: file.path)
    try await writer.write { db in
      try db.execute(sql: "CREATE TABLE private_auth (allowed BOOLEAN NOT NULL); INSERT INTO private_auth VALUES (1)")
    }
    let pool = ReadPool(path: file.path, capacity: 1)
    let (rows, region) = try await pool.run("SELECT id FROM sessions ORDER BY id", resolving: { snapshot in
      let allowed = try snapshot.rows(Authorization.all).first?.allowed
      #expect(allowed == true)
      try writer.write { db in
        try db.execute(sql: "UPDATE private_auth SET allowed = 0; INSERT INTO sessions (id) VALUES ('after-revocation')")
      }
      return .shared()
    })
    #expect(rows.rows == [[.text("a")], [.text("hidden")]])
    #expect(region.names == ["private_auth", "sessions"])

    await #expect(throws: ReadError.forbidden("private_auth")) {
      _ = try await pool.run("SELECT allowed FROM private_auth", resolving: { snapshot in
        let allowed = try snapshot.rows(Authorization.all).first?.allowed
        #expect(allowed == false)
        return .shared()
      })
    }
    let (next, _) = try await pool.run("SELECT id FROM sessions ORDER BY id", resolving: { snapshot in
      let allowed = try snapshot.rows(Authorization.all).first?.allowed
      #expect(allowed == false)
      return .shared()
    })
    #expect(next.rows.count == 3)
    try await pool.close()
  }
}
