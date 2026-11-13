import GRDB
@testable import SpaceCore
import Testing

struct Migration040Tests {
  @Test func onlyUnfinishedInferencesGetCreatorsWhilePayloadsStayUnchanged() async throws {
    let database = try DatabaseQueue()
    try await database.write { db in
      try db.execute(sql: """
      CREATE TABLE wuwei_job (address TEXT PRIMARY KEY, params BLOB NOT NULL, phase TEXT NOT NULL DEFAULT 'new', wake_at INTEGER);
      CREATE TABLE wuwei_mail (id INTEGER PRIMARY KEY AUTOINCREMENT, recipient TEXT NOT NULL, payload BLOB NOT NULL);
      INSERT INTO wuwei_job (address, params, phase) VALUES
        ('InferenceJob/active-session-id:236:51:0', X'7B7D', 'live'),
        ('InferenceJob/new-session-id:0:38:1', X'7B7D', 'new'),
        ('InferenceJob/done-session-id:0:38:0', X'7B7D', 'done'),
        ('ToolCallJob/tool-session-id:0:39', X'7B7D', 'live'),
        ('CompactionJob/fold-session-id:0:39', X'7B7D', 'live');
      INSERT INTO wuwei_mail (recipient, payload) VALUES ('SessionCell/old', X'7B7D');
      """)
      try Migration040.apply(.init(db))
      let jobs = try Row.fetchAll(db, sql: "SELECT address, phase, creator, hex(params) AS payload FROM wuwei_job ORDER BY address")
      #expect(jobs.map { $0["address"] as String } == [
        "CompactionJob/fold-session-id:0:39", "InferenceJob/active-session-id:236:51:0",
        "InferenceJob/done-session-id:0:38:0", "InferenceJob/new-session-id:0:38:1", "ToolCallJob/tool-session-id:0:39",
      ])
      #expect(jobs.map { $0["phase"] as String } == ["live", "live", "done", "new", "live"])
      #expect(jobs.map { $0["creator"] as String? } == [nil, "SessionCell/active-session-id", nil, "SessionCell/new-session-id", nil])
      #expect(jobs.map { $0["payload"] as String } == Array(repeating: "7B7D", count: 5))
      let mail = try Row.fetchOne(db, sql: "SELECT recipient, hex(payload) AS payload, lifecycle FROM wuwei_mail")
      #expect(mail?["recipient"] as String? == "SessionCell/old")
      #expect(mail?["lifecycle"] as String? == nil)
      #expect(mail?["payload"] as String? == "7B7D")
    }
  }
}
