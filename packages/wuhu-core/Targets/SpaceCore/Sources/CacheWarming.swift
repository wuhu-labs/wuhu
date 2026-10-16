import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import StructuredQueries

let cacheWarmingSchemaSQL = """
CREATE TABLE IF NOT EXISTS "session_cache_warming" (
  "session_id" TEXT NOT NULL PRIMARY KEY REFERENCES "sessions" ("id") ON DELETE CASCADE,
  "next_ping_at" REAL NOT NULL,
  "interval_seconds" INTEGER NOT NULL,
  "ping_count" INTEGER NOT NULL,
  "warming_origin" INTEGER NOT NULL DEFAULT 0,
  "last_offer_tokens" INTEGER
);
"""

@Table("session_cache_warming")
struct CacheWarmingRow {
  @Column("session_id", primaryKey: true) var sessionID: String
  @Column("next_ping_at") var nextPingAt: Double
  @Column("interval_seconds") var intervalSeconds: Int
  @Column("ping_count") var pingCount: Int
  @Column("warming_origin") var warmingOrigin: Bool = false
}

@Table("sessions")
private struct WarmingAgentRow {
  var id: String
  var kind: String
  var lifecycle: String
}

extension SessionStore {
  public func cacheWarmingAgents() async throws -> [SessionID] {
    try await writer.read { db in
      try WarmingAgentRow.where { $0.kind.eq("agent") && $0.lifecycle.eq("live") }
        .select { $0.id }.fetchAll(db).map { SessionID($0) }
    }
  }

  public func scheduleCacheWarming(_ id: SessionID, intervalSeconds: Int) async throws {
    let now = dateGen.now.timeIntervalSince1970
    try await writer.write { db in
      guard try Sessions.record(id.rawValue, in: db).kind == .agent else { return }
      if var row = try CacheWarmingRow.where({ $0.sessionID.eq(id.rawValue) }).fetchOne(db) {
        row.nextPingAt += Double(intervalSeconds - row.intervalSeconds)
        row.intervalSeconds = intervalSeconds
        try CacheWarmingRow.upsert { row }.execute(db)
      } else {
        let row = CacheWarmingRow(sessionID: id.rawValue, nextPingAt: now + Double(intervalSeconds), intervalSeconds: intervalSeconds, pingCount: 0)
        try CacheWarmingRow.insert { row }.execute(db)
      }
    }
  }

  public func discardPendingCacheWarming(_ id: SessionID) async throws -> Transcript {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    return try await writer.write { db in
      let original = try Sessions.transcript(id.rawValue, in: db)
      let transcript = original.discardingPendingCacheWarming()
      for (before, after) in zip(original.items, transcript.items) where before != after {
        let payload = try Sessions.encode(after)
        try SessionContentRow.where { $0.sessionID.eq(id.rawValue) && $0.id.eq(after.id.uuidString.lowercased()) }
          .update { $0.payload = #bind(payload) }.execute(db)
      }
      try Sessions.refreshWork(id.rawValue, transcript: transcript, now: now, in: db)
      return transcript
    }
  }

  public func deferOverdueCacheWarming(excluding: Set<SessionID> = []) async throws {
    let now = dateGen.now.timeIntervalSince1970
    try await writer.write { db in
      for var row in try CacheWarmingRow.where({ $0.nextPingAt <= now }).fetchAll(db) where !excluding.contains(SessionID(row.sessionID)) {
        row.nextPingAt = now + Double(row.intervalSeconds)
        try CacheWarmingRow.upsert { row }.execute(db)
      }
    }
  }

  @discardableResult
  public func enqueueCacheWarming(_ id: SessionID, maxPings: Int, floorTokens: Int, images: ImageLimits, quotaLow: Bool) async throws -> Bool {
    @Dependency(\.uuid) var uuid
    let noticeID = uuid()
    let now = dateGen.now
    let enqueued = try await writer.write { db -> Bool in
      let record = try Sessions.record(id.rawValue, in: db)
      let kernel = switch record.executor { case .kernel, .modelGroup: true; case .claudeCode, .contractor: false }
      guard record.kind == .agent, record.lifecycle == .live, record.hold == .normal, record.work == .noWork,
            !self.archiveReservations.contains(id), kernel,
            var row = try CacheWarmingRow.where({ $0.sessionID.eq(id.rawValue) }).fetchOne(db),
            row.nextPingAt <= now.timeIntervalSince1970, row.pingCount < maxPings,
            try Sessions.transcript(id.rawValue, in: db).reachesCacheWarmingFloor(floorTokens, images: images) else { return false }
      row.nextPingAt = now.timeIntervalSince1970 + Double(row.intervalSeconds)
      if quotaLow {
        row.pingCount = maxPings
        try CacheWarmingRow.upsert { row }.execute(db)
        return false
      }
      row.pingCount += 1
      row.warmingOrigin = true
      try CacheWarmingRow.upsert { row }.execute(db)
      let text = """
      <cache-warming-notice>
      This system notice keeps the prompt cache warm. It is not a message from a person and creates no reply obligation.
      Judge whether you expect more work soon. If you don't, call the compact tool now: a compacted context below the warming floor gets no more of these notices. If you do, end this turn without a reply; that is normal.
      </cache-warming-notice>
      """
      _ = try Sessions.enqueue(id.rawValue, input: .notification(.init(id: noticeID, timestamp: now, kind: .context, subscriptionID: SubscriptionID("cache-warming"), content: .init(text: text))), nowDate: now, in: db)
      return true
    }
    if enqueued { signals.post(id) }
    return enqueued
  }
}

extension CacheWarmingRow {
  static func recordInference(_ key: String, origin: Bool?, now: Date, in db: Database) throws {
    guard var row = try Self.where({ $0.sessionID.eq(key) }).fetchOne(db) else { return }
    row.nextPingAt = now.timeIntervalSince1970 + Double(row.intervalSeconds)
    row.warmingOrigin = origin ?? row.warmingOrigin
    if !row.warmingOrigin { row.pingCount = 0 }
    try Self.upsert { row }.execute(db)
  }

  static func reset(_ key: String, in db: Database) throws {
    try Self.where { $0.sessionID.eq(key) }.delete().execute(db)
  }
}
