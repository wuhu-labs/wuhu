import GRDB
import Logging

// Subscriptions get an owner that is a session or a group, a name, a status
// and a log of their handler firings; what an observer makes records the
// firing it was made in; an inference may be a group's, with no session.
enum Migration009 {
  static func apply(_ db: Database) throws {
    let moved = try run(db)
    Logger(label: "wuhu.migration").notice("migration 009: \(moved) session subscriptions moved to subscription_slots")
  }

  static func run(_ db: Database) throws -> Int {
    try db.execute(sql: """
    CREATE TABLE subscription_slots (
      owner_kind TEXT NOT NULL CHECK (owner_kind IN ('session', 'group')),
      owner TEXT NOT NULL,
      subscription_id TEXT NOT NULL,
      name TEXT,
      status TEXT NOT NULL CHECK (status IN ('armed', 'paused')),
      sessions_per_hour INTEGER,
      payload TEXT NOT NULL,
      next_fire_at TEXT,
      marker TEXT,
      last_fired_at TEXT,
      armed_at TEXT NOT NULL,
      PRIMARY KEY (owner_kind, owner, subscription_id),
      CHECK (owner_kind = 'session' OR (name IS NOT NULL AND sessions_per_hour IS NOT NULL))
    );
    CREATE UNIQUE INDEX subscription_slots_by_name ON subscription_slots (owner, name) WHERE owner_kind = 'group';

    INSERT INTO subscription_slots (owner_kind, owner, subscription_id, status, payload, next_fire_at, marker, last_fired_at, armed_at)
    SELECT 'session', session_id, subscription_id, 'armed', payload, next_fire_at, marker, last_fired_at, armed_at
    FROM session_subscriptions;
    DROP TABLE session_subscriptions;

    CREATE TABLE subscription_firings (
      id TEXT PRIMARY KEY,
      owner_kind TEXT NOT NULL,
      owner TEXT NOT NULL,
      subscription TEXT NOT NULL,
      name TEXT,
      grp TEXT NOT NULL,
      at TEXT NOT NULL,
      outcome TEXT NOT NULL CHECK (outcome IN ('running', 'ok', 'failed', 'cancelled', 'interrupted')),
      error TEXT,
      effects JSON_TEXT
    );
    CREATE INDEX subscription_firings_by_subscription ON subscription_firings (owner_kind, owner, subscription, at);
    CREATE INDEX subscription_firings_no_effects ON subscription_firings (at) WHERE effects IS NULL;

    ALTER TABLE sessions ADD COLUMN firing TEXT;
    ALTER TABLE requests ADD COLUMN firing TEXT;
    ALTER TABLE messages ADD COLUMN firing TEXT;
    CREATE INDEX sessions_by_firing ON sessions (firing) WHERE firing IS NOT NULL;
    CREATE INDEX requests_by_firing ON requests (firing) WHERE firing IS NOT NULL;
    CREATE INDEX messages_by_firing ON messages (firing) WHERE firing IS NOT NULL;
    CREATE INDEX revision_actors_by_via ON revision_actors (via);

    CREATE TABLE inferences_009 (
      "id" TEXT NOT NULL PRIMARY KEY,
      "session" TEXT,
      "at" TEXT NOT NULL,
      "provider" TEXT NOT NULL,
      "model" TEXT NOT NULL,
      "served_model" TEXT,
      "effort" TEXT NOT NULL,
      "input" INTEGER,
      "cache_read" INTEGER,
      "cache_write" INTEGER,
      "output" INTEGER,
      "reasoning" INTEGER,
      "outcome" TEXT NOT NULL,
      "error" TEXT,
      "duration_ms" INTEGER,
      "ttft_ms" INTEGER,
      "grp" TEXT NOT NULL,
      "firing" TEXT,
      CHECK ("session" IS NOT NULL OR "firing" IS NOT NULL)
    );
    INSERT INTO inferences_009 (id, session, at, provider, model, served_model, effort, input, cache_read, cache_write, output, reasoning, outcome, error, duration_ms, ttft_ms, grp)
    SELECT id, session, at, provider, model, served_model, effort, input, cache_read, cache_write, output, reasoning, outcome, error, duration_ms, ttft_ms, grp
    FROM inferences;
    DROP TABLE inferences;
    ALTER TABLE inferences_009 RENAME TO inferences;
    CREATE INDEX inferences_by_session_at ON inferences (session, at);
    CREATE INDEX inferences_by_grp_at ON inferences (grp, at);
    """)
    // A session's handler subscription is named after its handler file.
    let handlers = try Row.fetchAll(db, sql: """
    SELECT owner, subscription_id, json_extract(payload, '$.handler') AS handler FROM subscription_slots
    WHERE json_type(payload, '$.handler') = 'text'
    """)
    for row in handlers {
      let handler: String = row["handler"]
      try db.execute(
        sql: "UPDATE subscription_slots SET name = ? WHERE owner_kind = 'session' AND owner = ? AND subscription_id = ?",
        arguments: [handlerName(handler), row["owner"] as String, row["subscription_id"] as String],
      )
    }
    return try Int.fetchOne(db, sql: "SELECT count(*) FROM subscription_slots")!
  }

  static func handlerName(_ path: String) -> String {
    let file = path.split(separator: "/").last.map(String.init) ?? path
    guard let dot = file.lastIndex(of: "."), dot != file.startIndex else { return file }
    return String(file[..<dot])
  }
}
