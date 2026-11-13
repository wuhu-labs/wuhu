import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MediaMigrationTests {
  @Test func upgradeDropsBlobOwnershipAndPreservesBlobBytes() async throws {
    let folder = try ScratchFolder("media-migration")
    let file = folder.url.appending(path: "space.sqlite")
    let original = try Space.open(file: file)
    let database = try RawDatabase(path: file.path)
    let bytes = Data([1, 2, 3])
    let hash = try await original.storeImage(bytes)
    try database.access { db in
      try db.execute(sql: "CREATE TABLE session_blobs (session_id TEXT NOT NULL, hash TEXT NOT NULL, PRIMARY KEY (session_id, hash))")
      try db.execute(sql: "INSERT INTO session_blobs VALUES (?, ?)", arguments: [UUID().uuidString, hash])
      try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = '005'")
    }
    let upgraded = try Space.open(file: file)
    #expect(try database.access { try !$0.tableExists("session_blobs") })
    #expect(try await upgraded.blobBytes(hash) == Array(bytes))
    let reopened = try Space.open(file: file)
    #expect(try await reopened.blobBytes(hash) == Array(bytes))
    try await reopened.close()
    try await upgraded.close()
    try await original.close()
  }
}
