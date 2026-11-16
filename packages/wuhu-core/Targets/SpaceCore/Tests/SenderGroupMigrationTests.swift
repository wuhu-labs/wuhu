import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import Scratch
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct SenderGroupMigrationTests {
  @Test func upgradeAndFreshSpaceShareASchemaAndMessagesStillLoad() async throws {
    let folder = try ScratchFolder("sender-group-drop")
    let file = folder.url.appending(path: "upgrade.sqlite")
    try RawDatabase.open(file.path) { db in
      try MigrationRunner(db: db, log: Logger(label: "migration"), date: .constant(Date(timeIntervalSince1970: 0)), baseline: Migrations.baseline, chains: []).migrate()
      try db.execute(sql: """
      INSERT INTO conversations (id, kind, window_messages, window_seconds, created_at, grp) VALUES ('box', 'box', 10, 900, '2026-01-01T00:00:00.000Z', 'shared');
      INSERT INTO messages (n, id, conversation_id, sender_id, sender_timezone, kind, content, created_at) VALUES (1, 'kept', 'box', 'person', 'UTC', 'message', '{"text":"kept text","attachments":[]}', '2026-01-01T00:00:00.000Z');
      INSERT INTO message_groups VALUES ('kept', 'old-group');
      """)
    }
    let upgraded = try Space.open(file: file)
    let fresh = try Space.open(file: folder.url.appending(path: "fresh.sqlite"))
    let upgradedShape = try RawDatabase.open(file.path, MigrationTests.schemaShape)
    let freshShape = try RawDatabase.open(fresh.databasePath, MigrationTests.schemaShape)
    #expect(upgradedShape.tables == freshShape.tables)
    #expect(upgradedShape.indexesAndTriggers == freshShape.indexesAndTriggers)
    #expect(upgradedShape.tables["message_groups"] == nil)
    #expect(upgraded.sessions.message(MessageID("kept"))?.content.text == "kept text")
    try await upgraded.close()
    let reopened = try Space.open(file: file)
    #expect(reopened.sessions.message(MessageID("kept"))?.sender.id == "person")
    try await reopened.close()
    try await fresh.close()
  }
}
