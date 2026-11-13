import DeterministicDependencies
import GRDB
import LoopCore
import SessionDomain
import struct SpaceContract.GroupID
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct SessionLegacyItemsTests {
  private static let payload = #"{"assistant":{"_0":{"content":"legacy bytes"}}}"#

  private func seed(_ space: Space, group: GroupID = .shared, payload: String = Self.payload) async throws -> SessionID {
    let session = try await space.sessions.createSession(group: group, title: "legacy", kind: .agent, createdBy: "owner", model: .test)
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO session_contents VALUES (?, 'same-id', ?)", arguments: [session.rawValue, payload])
      try db.execute(sql: "INSERT INTO session_pointers VALUES (?, 0, 0, 'same-id'), (?, 2, 7, 'same-id')", arguments: [session.rawValue, session.rawValue])
    }
    return session
  }

  @Test func projectsEveryPointerWithoutDecodingOrChangingThePayload() async throws {
    let space = try makeSpace()
    let first = try await seed(space)
    let second = try await seed(space, payload: #"{"unknownOldKind":{}}"#)
    let rows = try await space.query("SELECT * FROM session_legacy_items WHERE session_id = ? ORDER BY generation, position", arguments: [.string(first.rawValue)])
    #expect(rows.columns == ["session_id", "generation", "position", "kind", "payload"])
    #expect(rows.rows == [
      [.text(first.rawValue), .integer(0), .integer(0), .text("assistant"), .text(Self.payload)],
      [.text(first.rawValue), .integer(2), .integer(7), .text("assistant"), .text(Self.payload)],
    ])
    #expect(try await space.query("SELECT kind, payload FROM session_legacy_items WHERE session_id = ? AND generation = 0", arguments: [.string(second.rawValue)]).rows == [[.text("unknownOldKind"), .text(#"{"unknownOldKind":{}}"#)]])
    #expect(try await space.validateQuery("SELECT * FROM session_legacy_items", as: .shared(.anonymous)).names == ["session_pointers", "session_contents", "sessions"])
    try await space.close()
  }

  @Test func sessionGroupsScopeUnqualifiedQualifiedAndWildcardQueries() async throws {
    let space = try makeSpace()
    let other = GroupID(rawValue: "other")
    let hidden = GroupID(rawValue: "hidden")
    try await space.writer.write { db in
      try db.execute(sql: "INSERT INTO groups (id, created_at) VALUES ('other', 'then'), ('hidden', 'then')")
    }
    let own = try await seed(space)
    let readable = try await seed(space, group: other)
    _ = try await seed(space, group: hidden)
    #expect(try await space.query("SELECT session_id FROM session_legacy_items WHERE generation = 0").rows == [[.text(own.rawValue)]])
    await #expect(throws: SpaceError.unknownRelation("wuhu://other.localspace/session_legacy_items")) {
      try await space.query("SELECT * FROM \"wuhu://other.localspace/session_legacy_items\"")
    }
    try await space.setGrant(.group, GroupID.shared.rawValue, role: .read, in: other, by: .anonymous, acting: other)
    #expect(try await space.query("SELECT session_id FROM \"wuhu://other.localspace/session_legacy_items\" WHERE generation = 0").rows == [[.text(readable.rawValue)]])
    #expect(try await space.query("SELECT grp, session_id FROM \"wuhu://*.localspace/session_legacy_items\" WHERE generation = 0 ORDER BY grp").rows == [
      [.text("other"), .text(readable.rawValue)], [.text("shared"), .text(own.rawValue)],
    ])
    #expect(try await space.query("SELECT session_id FROM session_legacy_items WHERE generation = 0").rows == [[.text(own.rawValue)]])
    #expect(try await space.query("SELECT session_id FROM session_legacy_items WHERE generation = 0", as: .init(actor: .anonymous, group: other)).rows == [[.text(readable.rawValue)]])
    await #expect(throws: SpaceError.unknownRelation("wuhu://hidden.localspace/session_legacy_items")) {
      try await space.query("SELECT * FROM \"wuhu://hidden.localspace/session_legacy_items\"")
    }
    try await space.removeGrant(.group, GroupID.shared.rawValue, in: other, by: .anonymous, acting: other)
    #expect(try await space.query("SELECT grp FROM \"wuhu://*.localspace/session_legacy_items\" WHERE generation = 0").rows == [[.text("shared")]])
    try await space.close()
  }

  @Test func theViewIsReadOnlyAndItsBackingTablesStayHidden() async throws {
    let space = try makeSpace()
    _ = try await seed(space)
    for sql in [
      "DELETE FROM session_legacy_items",
      "UPDATE session_legacy_items SET payload = '{}'",
      "INSERT INTO session_legacy_items (session_id, generation, position, kind, payload) VALUES ('s', 0, 0, 'assistant', '{}')",
    ] {
      await #expect(throws: SpaceError.queryNotReadOnly) { try await space.query(sql) }
    }
    for table in ["session_pointers", "session_contents", "session_generations"] {
      for sql in [
        "SELECT * FROM \(table)",
        "SELECT count(*) FROM \(table)",
        "WITH session_legacy_items AS (SELECT * FROM \(table)) SELECT * FROM session_legacy_items",
      ] {
        await #expect(throws: SpaceError.queryForbiddenTable(table)) { try await space.query(sql) }
      }
    }
    #expect(try await space.query("SELECT count(*) FROM session_legacy_items").rows == [[.integer(2)]])
    try await space.close()
  }
}
