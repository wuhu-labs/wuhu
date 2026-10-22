import DeterministicDependencies
import Foundation
import GRDB
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MediaMigrationTests {
  @Test func upgradeDropsBlobOwnershipAndPreservesBlobBytes() async throws {
    let database = try DatabaseQueue(path: "file:/media-migration-\(UUID())?vfs=memdb")
    let original = try Space(writer: database)
    let bytes = Data([1, 2, 3])
    let hash = try await original.storeImage(bytes)
    try await database.write { db in
      try db.execute(sql: "CREATE TABLE session_blobs (session_id TEXT NOT NULL, hash TEXT NOT NULL, PRIMARY KEY (session_id, hash))")
      try db.execute(sql: "INSERT INTO session_blobs VALUES (?, ?)", arguments: [UUID().uuidString, hash])
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '005'")
    }
    let upgraded = try Space(writer: DatabaseQueue(path: database.path))
    #expect(try await database.read { try !$0.tableExists("session_blobs") })
    #expect(try await upgraded.blobBytes(hash) == Array(bytes))
    let reopened = try Space(writer: DatabaseQueue(path: database.path))
    #expect(try await reopened.blobBytes(hash) == Array(bytes))
    try await reopened.close()
    try await upgraded.close()
    try await original.close()
  }
}
