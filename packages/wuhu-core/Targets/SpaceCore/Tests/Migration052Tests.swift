import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Scratch
@testable import SpaceCore
import SpaceFS
import Testing

@Suite(.deterministicDependencies)
struct Migration052Tests {
  @Test(arguments: ["/kept.wmd", "/kept.canvas"])
  func anExistingDocumentGainsItsLineageAndOpens(_ path: String) async throws {
    let folder = try ScratchFolder("document-lineage-upgrade")
    let file = folder.url.appending(path: "space.sqlite")
    let original = try Space.open(file: file)
    let source = path.hasSuffix(".canvas") ? "- sticky {@0,0} Kept\n" : "# Kept\n"
    let token = try await original.fs(.shared).write(path, Data(source.utf8), ifMatch: nil)
    let expected = try await original.fs(.shared).read(path).1
    try await original.close()

    let fixture = try RawDatabase(path: file.path)
    try fixture.access { db in
      #expect(try db.int("SELECT count(*) FROM document_state") == 1)
      try db.execute(sql: """
      DROP TABLE document_lineage;
      DROP TABLE document_pending_checkpoint;
      DELETE FROM file_document_checkpoint;
      DELETE FROM grdb_migrations WHERE identifier = '052';
      """)
    }

    let migrated = try Space.open(file: file)
    try fixture.access { db in
      let row = try #require(try db.row("SELECT owner, lineage, seq, seed_rev FROM document_lineage"))
      #expect(row["owner"] as String == "shared" + path)
      #expect(row["lineage"] as Int == 1)
      #expect(row["seq"] as Int == 0)
      #expect(row["seed_rev"] as Int? == token.rev)
      #expect(try db.int("SELECT count(*) FROM document_pending_checkpoint") == 0)
    }
    let client = try await DocumentClient.join(migrated, path)
    #expect(client.replica.text == String(decoding: expected, as: UTF8.self))
    #expect(try await migrated.fs(.shared).read(path).1 == expected)
    try await migrated.close()
  }
}
