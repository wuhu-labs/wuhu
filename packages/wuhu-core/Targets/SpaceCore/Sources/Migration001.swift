import GRDB

enum Migration001 {
  static func apply(_ db: Database) throws {
    let fresh = try !db.tableExists("fs_heads")
    if !fresh {
      guard try db.tableExists("schema_compactions"),
            try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM schema_compactions WHERE name = 'wuhu-45')") == true
      else { throw SpaceError.needsMigration("wuhu-45") }
    }
    try db.execute(sql: schema)
    if fresh {
      try db.execute(sql: "INSERT INTO schema_compactions (name, applied_at) VALUES ('wuhu-45-links', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))")
    }
    if try !db.columns(in: "machine_execs").contains(where: { $0.name == "tool_spec" }) {
      try db.execute(sql: "ALTER TABLE machine_execs ADD COLUMN tool_spec TEXT")
    }
    if try !db.columns(in: "machine_execs").contains(where: { $0.name == "tool_end_owed" }) {
      try db.execute(sql: "ALTER TABLE machine_execs ADD COLUMN tool_end_owed INTEGER NOT NULL DEFAULT 0")
    }
    if try !db.columns(in: "session_api_receipts").contains(where: { $0.name == "request" }) {
      try db.execute(sql: "ALTER TABLE session_api_receipts ADD COLUMN request TEXT")
    }
    if try db.tableExists("exec_jobs") {
      try db.execute(sql: """
      UPDATE machine_execs SET tool_end_owed = 1,
        tool_spec = (SELECT spec FROM exec_jobs WHERE exec_id = machine_execs.id)
      WHERE id IN (SELECT exec_id FROM exec_jobs)
      """)
      try db.execute(sql: "DELETE FROM exec_jobs")
    }
  }

  private static let schema = """
  CREATE TABLE IF NOT EXISTS "execution_worker_owners" (
    "incarnation" TEXT NOT NULL PRIMARY KEY
  );
  CREATE TABLE IF NOT EXISTS "session_worker_assignments" (
    "session_id" TEXT NOT NULL REFERENCES "sessions" ("id") ON DELETE CASCADE,
    "incarnation" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "incarnation")
  );
  CREATE TABLE IF NOT EXISTS "worker_script_owners" (
    "session_id" TEXT NOT NULL REFERENCES "sessions" ("id") ON DELETE CASCADE,
    "script_id" TEXT NOT NULL,
    "incarnation" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "script_id", "incarnation")
  );
  CREATE TABLE IF NOT EXISTS "session_worker_incarnations" (
    "session_id" TEXT NOT NULL REFERENCES "sessions" ("id") ON DELETE CASCADE,
    "incarnation" TEXT NOT NULL,
    "died_at" REAL,
    PRIMARY KEY ("session_id", "incarnation")
  );
  CREATE TABLE IF NOT EXISTS machine_v2_key_check (id TEXT PRIMARY KEY, sealed TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS machine_v2_retention (id TEXT PRIMARY KEY, grp TEXT NOT NULL, kind TEXT NOT NULL, expired_at TEXT NOT NULL);
  CREATE INDEX IF NOT EXISTS machine_v2_retention_expiry ON machine_v2_retention(grp, kind, expired_at);
  CREATE TABLE IF NOT EXISTS machine_v2_maintenance (id TEXT PRIMARY KEY, ran_at TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS machine_v2_members (machine_id TEXT PRIMARY KEY REFERENCES machines(id), grp TEXT NOT NULL, created_at TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS machine_v2_presence (machine_id TEXT PRIMARY KEY, grp TEXT NOT NULL, state TEXT NOT NULL, description TEXT, observed_at TEXT NOT NULL, reason TEXT);
  CREATE TABLE IF NOT EXISTS machine_v2_operations (id TEXT PRIMARY KEY, grp TEXT NOT NULL, owner_scope TEXT NOT NULL, invocation_key TEXT NOT NULL, machine_id TEXT NOT NULL, correlation_id TEXT NOT NULL, input_digest TEXT NOT NULL, dispatch_consumed INTEGER NOT NULL, record TEXT NOT NULL, active INTEGER NOT NULL, reserved_bytes INTEGER NOT NULL, created_at TEXT NOT NULL, UNIQUE(grp, owner_scope, invocation_key));
  CREATE TABLE IF NOT EXISTS machine_v2_channels (id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES machine_v2_operations(id) ON DELETE CASCADE, name TEXT NOT NULL, committed TEXT NOT NULL, accepted TEXT NOT NULL, pending TEXT);
  CREATE TABLE IF NOT EXISTS machine_v2_output (id TEXT PRIMARY KEY, operation_id TEXT NOT NULL REFERENCES machine_v2_operations(id) ON DELETE CASCADE, channel TEXT NOT NULL, sequence INTEGER NOT NULL, payload TEXT NOT NULL);
  CREATE TABLE IF NOT EXISTS machine_v2_trace (id TEXT PRIMARY KEY, grp TEXT NOT NULL, request_id TEXT NOT NULL, correlation_id TEXT NOT NULL, path TEXT NOT NULL, event TEXT NOT NULL, start_at TEXT NOT NULL, elapsed_ms INTEGER NOT NULL, status INTEGER, head_ms INTEGER, error_code TEXT, problem_id INTEGER);
  CREATE INDEX IF NOT EXISTS machine_v2_trace_correlation ON machine_v2_trace(grp, correlation_id, start_at);
  CREATE TABLE IF NOT EXISTS machine_v2_problem_index (id TEXT PRIMARY KEY, grp TEXT NOT NULL, fingerprint TEXT NOT NULL, row_id INTEGER NOT NULL);
  CREATE TABLE IF NOT EXISTS machine_v2_incidents (id TEXT PRIMARY KEY, grp TEXT NOT NULL, trace_group TEXT NOT NULL, fingerprint TEXT NOT NULL, correlation_id TEXT, problem_id INTEGER);
  CREATE TABLE IF NOT EXISTS "session_model_routes" (
    "session_id" TEXT NOT NULL PRIMARY KEY REFERENCES "sessions" ("id") ON DELETE CASCADE,
    "grp" TEXT NOT NULL,
    "group_id" TEXT,
    "member_id" TEXT,
    "provider" TEXT NOT NULL,
    "model" TEXT NOT NULL,
    "route_epoch" TEXT NOT NULL,
    "phase" TEXT NOT NULL,
    "payload" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "session_model_route_history" (
    "decision_id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    "session_id" TEXT NOT NULL REFERENCES "sessions" ("id") ON DELETE CASCADE,
    "route_epoch" TEXT NOT NULL,
    "grp" TEXT NOT NULL,
    "group_id" TEXT,
    "member_id" TEXT,
    "provider" TEXT NOT NULL,
    "model" TEXT NOT NULL,
    "reason" TEXT NOT NULL,
    "placed_at" TEXT NOT NULL,
    "payload" TEXT NOT NULL,
    UNIQUE ("session_id", "route_epoch")
  );
  CREATE TABLE IF NOT EXISTS "session_cache_warming" (
    "session_id" TEXT NOT NULL PRIMARY KEY REFERENCES "sessions" ("id") ON DELETE CASCADE,
    "next_ping_at" REAL NOT NULL,
    "interval_seconds" INTEGER NOT NULL,
    "ping_count" INTEGER NOT NULL,
    "warming_origin" INTEGER NOT NULL DEFAULT 0,
    "last_offer_tokens" INTEGER
  );
  CREATE TABLE IF NOT EXISTS "revisions" (
    "rev" INTEGER NOT NULL PRIMARY KEY,
    "mtime" TEXT NOT NULL,
    "grp" TEXT NOT NULL DEFAULT ''
  );
  CREATE TRIGGER IF NOT EXISTS "revisions_grp_required" BEFORE INSERT ON "revisions" WHEN NEW."grp" = ''
    BEGIN SELECT RAISE(ABORT, 'grp required: revisions'); END;
  -- Who a page's revision acts for, and the page; only page writes have a row.
  CREATE TABLE IF NOT EXISTS "revision_actors" (
    "rev" INTEGER NOT NULL PRIMARY KEY,
    "actor" TEXT,
    "via" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "blobs" (
    "hash" TEXT NOT NULL PRIMARY KEY,
    "content" BLOB NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "fs_versions" (
    "grp" TEXT NOT NULL,
    "path" TEXT NOT NULL,
    "rev" INTEGER NOT NULL,
    "kind" TEXT,
    "blob_hash" TEXT,
    "op" TEXT NOT NULL,
    "aux" TEXT,
    PRIMARY KEY ("grp", "path", "rev")
  );
  CREATE INDEX IF NOT EXISTS "fs_versions_by_grp_rev" ON "fs_versions" ("grp", "rev");
  CREATE TABLE IF NOT EXISTS "fs_heads" (
    "grp" TEXT NOT NULL,
    "path" TEXT NOT NULL,
    "parent_path" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "blob_hash" TEXT,
    "size" INTEGER NOT NULL,
    "line_count" INTEGER,
    "etag" TEXT NOT NULL,
    "rev" INTEGER NOT NULL,
    "mtime" TEXT NOT NULL,
    PRIMARY KEY ("grp", "path")
  );
  CREATE INDEX IF NOT EXISTS "fs_heads_by_grp_parent" ON "fs_heads" ("grp", "parent_path");
  CREATE TABLE IF NOT EXISTS "docs" (
    "grp" TEXT NOT NULL,
    "path" TEXT NOT NULL,
    "title" TEXT NOT NULL,
    "kind" TEXT,
    "status" TEXT,
    PRIMARY KEY ("grp", "path")
  );
  CREATE TABLE IF NOT EXISTS "links" (
    "grp" TEXT NOT NULL,
    "src" TEXT NOT NULL,
    "dst_grp" TEXT NOT NULL,
    "dst" TEXT NOT NULL,
    PRIMARY KEY ("grp", "src", "dst_grp", "dst")
  );
  CREATE INDEX IF NOT EXISTS "links_by_dst" ON "links" ("dst_grp", "dst");
  CREATE TABLE IF NOT EXISTS "doc_custom_attrs" (
    "grp" TEXT NOT NULL,
    "path" TEXT NOT NULL,
    "name" TEXT NOT NULL,
    "ord" INTEGER NOT NULL,
    "value" TEXT NOT NULL,
    PRIMARY KEY ("grp", "path", "name", "ord")
  );
  CREATE TABLE IF NOT EXISTS "tables" (
    "grp" TEXT NOT NULL,
    "path" TEXT NOT NULL,
    "created_rev" INTEGER NOT NULL,
    PRIMARY KEY ("grp", "path")
  );
  CREATE TABLE IF NOT EXISTS "table_schema_versions" (
    "grp" TEXT NOT NULL,
    "path" TEXT NOT NULL,
    "rev" INTEGER NOT NULL,
    "header_json" TEXT NOT NULL,
    PRIMARY KEY ("grp", "path", "rev")
  );
  CREATE TABLE IF NOT EXISTS "table_rows" (
    "grp" TEXT NOT NULL,
    "path" TEXT NOT NULL,
    "row_id" INTEGER NOT NULL,
    "created_rev" INTEGER NOT NULL,
    "deleted_rev" INTEGER,
    "payload" TEXT NOT NULL,
    PRIMARY KEY ("grp", "path", "row_id", "created_rev")
  );
  CREATE TABLE IF NOT EXISTS "machines" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
    "name" TEXT,
    "created_at" TEXT NOT NULL,
    "grp" TEXT NOT NULL DEFAULT ''
  );
  CREATE TRIGGER IF NOT EXISTS "machines_grp_required" BEFORE INSERT ON "machines" WHEN NEW."grp" = ''
    BEGIN SELECT RAISE(ABORT, 'grp required: machines'); END;
  CREATE UNIQUE INDEX IF NOT EXISTS "machines_by_account" ON "machines" ("account_id");
  CREATE TABLE IF NOT EXISTS "machine_execs" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "machine_id" TEXT NOT NULL,
    "stream_id" INTEGER NOT NULL,
    "command" TEXT NOT NULL,
    "caller" TEXT,
    "tool_call_id" TEXT,
    "started_at" TEXT NOT NULL,
    "terminal_state" TEXT,
    "kill_delivered" INTEGER NOT NULL DEFAULT 0,
    "grp" TEXT NOT NULL DEFAULT '',
    "tool_spec" TEXT,
    "tool_end_owed" INTEGER NOT NULL DEFAULT 0
  );
  CREATE TRIGGER IF NOT EXISTS "machine_execs_grp_required" BEFORE INSERT ON "machine_execs" WHEN NEW."grp" = ''
    BEGIN SELECT RAISE(ABORT, 'grp required: machine_execs'); END;
  CREATE UNIQUE INDEX IF NOT EXISTS "machine_execs_by_stream" ON "machine_execs" ("machine_id", "stream_id");
  CREATE UNIQUE INDEX IF NOT EXISTS "machine_execs_by_tool_call" ON "machine_execs" ("caller", "tool_call_id")
    WHERE "tool_call_id" IS NOT NULL;
  CREATE TABLE IF NOT EXISTS "script_execs" (
    "exec_id" TEXT NOT NULL PRIMARY KEY,
    "script_id" TEXT NOT NULL,
    "session_id" TEXT NOT NULL,
    "grp" TEXT NOT NULL DEFAULT ''
  );
  CREATE TRIGGER IF NOT EXISTS "script_execs_grp_required" BEFORE INSERT ON "script_execs" WHEN NEW."grp" = ''
    BEGIN SELECT RAISE(ABORT, 'grp required: script_execs'); END;
  -- A tripwire: an old binary's CREATE INDEX of this name fails at open instead of serving unscoped data.
  CREATE TABLE IF NOT EXISTS "fs_heads_by_parent" ("wuhu45" INTEGER);
  CREATE TABLE IF NOT EXISTS "blob_objects" (
    "hash" TEXT NOT NULL PRIMARY KEY,
    "object_key" TEXT NOT NULL,
    "size" INTEGER NOT NULL,
    "line_count" INTEGER
  );
  CREATE TABLE IF NOT EXISTS "sessions" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "allocation" INTEGER NOT NULL UNIQUE,
    "kind" TEXT NOT NULL,
    "parent" TEXT,
    "title" TEXT NOT NULL,
    "tags" TEXT NOT NULL,
    "created_by" TEXT NOT NULL,
    "executor" TEXT NOT NULL,
    "executor_config" TEXT NOT NULL,
    "created_at" TEXT NOT NULL,
    "last_activity_at" TEXT NOT NULL,
    "hold" TEXT NOT NULL,
    "work" TEXT NOT NULL,
    "lifecycle" TEXT NOT NULL,
    "grace_expires_at" TEXT,
    "error_message" TEXT,
    "run_state" TEXT NOT NULL,
    "run_heartbeat_at" TEXT,
    "run_progress_at" TEXT,
    "grp" TEXT NOT NULL DEFAULT ''
  );
  CREATE TRIGGER IF NOT EXISTS "sessions_grp_required" BEFORE INSERT ON "sessions" WHEN NEW."grp" = ''
    BEGIN SELECT RAISE(ABORT, 'grp required: sessions'); END;
  CREATE INDEX IF NOT EXISTS "sessions_by_grp" ON "sessions" ("grp", "last_activity_at");
  CREATE TABLE IF NOT EXISTS "session_runtime" (
    "session_id" TEXT NOT NULL PRIMARY KEY,
    "generation" INTEGER NOT NULL,
    "queue_tail" INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "session_generations" (
    "session_id" TEXT NOT NULL,
    "generation" INTEGER NOT NULL,
    "kept_count" INTEGER NOT NULL,
    PRIMARY KEY ("session_id", "generation")
  );
  CREATE TABLE IF NOT EXISTS "session_contents" (
    "session_id" TEXT NOT NULL,
    "id" TEXT NOT NULL,
    "payload" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "id")
  );
  CREATE TABLE IF NOT EXISTS "session_pointers" (
    "session_id" TEXT NOT NULL,
    "generation" INTEGER NOT NULL,
    "position" INTEGER NOT NULL,
    "content_id" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "generation", "position")
  );
  CREATE TABLE IF NOT EXISTS "session_queue" (
    "session_id" TEXT NOT NULL,
    "id" INTEGER NOT NULL,
    "input_id" TEXT NOT NULL,
    "payload" TEXT NOT NULL,
    "enqueued_at" TEXT NOT NULL,
    "drained_at" TEXT,
    PRIMARY KEY ("session_id", "id")
  );
  CREATE UNIQUE INDEX IF NOT EXISTS "session_queue_dedup" ON "session_queue" ("session_id", "input_id");
  CREATE TABLE IF NOT EXISTS "session_receipts" (
    "session_id" TEXT NOT NULL,
    "tool_call_id" TEXT NOT NULL,
    "payload" TEXT NOT NULL,
    "recorded_at" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "tool_call_id")
  );
  CREATE TABLE IF NOT EXISTS "session_api_receipts" (
    "session_id" TEXT NOT NULL,
    "tool_call_id" TEXT NOT NULL,
    "status" INTEGER NOT NULL,
    "body" TEXT NOT NULL,
    "recorded_at" TEXT NOT NULL,
    "request" TEXT,
    PRIMARY KEY ("session_id", "tool_call_id")
  );
  CREATE TABLE IF NOT EXISTS "session_blobs" (
    "session_id" TEXT NOT NULL,
    "hash" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "hash")
  );
  CREATE TABLE IF NOT EXISTS "session_subscriptions" (
    "session_id" TEXT NOT NULL,
    "subscription_id" TEXT NOT NULL,
    "payload" TEXT NOT NULL,
    "next_fire_at" TEXT,
    "marker" TEXT,
    "last_fired_at" TEXT,
    "armed_at" TEXT NOT NULL,
    PRIMARY KEY ("session_id", "subscription_id")
  );
  CREATE TABLE IF NOT EXISTS "session_commands" (
    "session_id" TEXT NOT NULL PRIMARY KEY,
    "kind" TEXT NOT NULL,
    "instructions" TEXT,
    "created_at" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "session_command_tokens" (
    "session_id" TEXT NOT NULL PRIMARY KEY,
    "token" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "session_context" (
    "session_id" TEXT NOT NULL PRIMARY KEY,
    "used_tokens" INTEGER NOT NULL,
    "max_tokens" INTEGER NOT NULL,
    "reported_at" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "conversations" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "kind" TEXT NOT NULL,
    "owner_session" TEXT,
    "window_messages" INTEGER NOT NULL,
    "window_seconds" INTEGER NOT NULL,
    "created_at" TEXT NOT NULL,
    "grp" TEXT NOT NULL DEFAULT ''
  );
  CREATE TRIGGER IF NOT EXISTS "conversations_grp_required" BEFORE INSERT ON "conversations" WHEN NEW."grp" = ''
    BEGIN SELECT RAISE(ABORT, 'grp required: conversations'); END;
  CREATE INDEX IF NOT EXISTS "conversations_by_grp" ON "conversations" ("grp");
  CREATE TABLE IF NOT EXISTS "conversation_titles" (
    "conversation_id" TEXT NOT NULL PRIMARY KEY,
    "title" TEXT
  );
  CREATE TABLE IF NOT EXISTS "conversation_members" (
    "conversation_id" TEXT NOT NULL,
    "member" TEXT NOT NULL,
    "member_kind" TEXT NOT NULL,
    "joined_at" TEXT NOT NULL,
    PRIMARY KEY ("conversation_id", "member")
  );
  CREATE TABLE IF NOT EXISTS "messages" (
    "n" INTEGER NOT NULL PRIMARY KEY,
    "id" TEXT NOT NULL,
    "conversation_id" TEXT NOT NULL,
    "sender_id" TEXT NOT NULL,
    "sender_session_id" TEXT,
    "sender_timezone" TEXT NOT NULL,
    "reply_target" TEXT,
    "kind" TEXT NOT NULL,
    "request_id" TEXT,
    "deadline_at" TEXT,
    "content" TEXT NOT NULL,
    "created_at" TEXT NOT NULL
  );
  CREATE UNIQUE INDEX IF NOT EXISTS "messages_by_id" ON "messages" ("id");
  CREATE INDEX IF NOT EXISTS "messages_by_conversation" ON "messages" ("conversation_id", "n");
  CREATE INDEX IF NOT EXISTS "messages_by_sender_session" ON "messages" ("sender_session_id", "n");
  CREATE INDEX IF NOT EXISTS "messages_by_request" ON "messages" ("request_id", "n");
  CREATE TABLE IF NOT EXISTS "notifications" (
    "n" INTEGER NOT NULL PRIMARY KEY,
    "recipient" TEXT NOT NULL,
    "source" TEXT NOT NULL,
    "kind" TEXT NOT NULL,
    "payload" TEXT NOT NULL,
    "created_at" TEXT NOT NULL,
    "grp" TEXT NOT NULL DEFAULT ''
  );
  CREATE TRIGGER IF NOT EXISTS "notifications_grp_required" BEFORE INSERT ON "notifications" WHEN NEW."grp" = ''
    BEGIN SELECT RAISE(ABORT, 'grp required: notifications'); END;
  CREATE INDEX IF NOT EXISTS "notifications_by_grp" ON "notifications" ("recipient", "grp", "n");
  CREATE INDEX IF NOT EXISTS "notifications_by_recipient" ON "notifications" ("recipient", "n");
  CREATE INDEX IF NOT EXISTS "notifications_by_source" ON "notifications" ("recipient", "kind", "source", "n");
  CREATE TABLE IF NOT EXISTS "watermarks" (
    "identity" TEXT NOT NULL,
    "source" TEXT NOT NULL,
    "last_read_n" INTEGER NOT NULL,
    PRIMARY KEY ("identity", "source")
  );
  CREATE TABLE IF NOT EXISTS "allocations" (
    "id" INTEGER PRIMARY KEY AUTOINCREMENT,
    "kind" TEXT NOT NULL,
    "created_by" TEXT NOT NULL,
    "created_at" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "allocation_freeze" (
    "id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1),
    "vocab_sha256" TEXT NOT NULL,
    "secret" BLOB NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "accounts" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "kind" TEXT NOT NULL CHECK ("kind" IN ('human', 'space', 'machine', 'contractor')),
    "name" TEXT,
    "created_at" TEXT NOT NULL,
    "removed_at" TEXT
  );
  CREATE TABLE IF NOT EXISTS "account_keys" (
    "pubkey" TEXT NOT NULL PRIMARY KEY,
    "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
    "capabilities" TEXT NOT NULL,
    "created_by" TEXT REFERENCES "accounts" ("id"),
    "created_at" TEXT NOT NULL,
    "expires_at" TEXT
  );
  CREATE INDEX IF NOT EXISTS "account_keys_by_account" ON "account_keys" ("account_id");
  CREATE TABLE IF NOT EXISTS "read_sessions" (
    "token_hash" TEXT NOT NULL PRIMARY KEY,
    "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
    "created_at" TEXT NOT NULL,
    "expires_at" TEXT NOT NULL,
    "grp" TEXT
  );
  CREATE INDEX IF NOT EXISTS "read_sessions_by_account" ON "read_sessions" ("account_id");
  CREATE TABLE IF NOT EXISTS "schema_compactions" (
    "name" TEXT NOT NULL PRIMARY KEY,
    "applied_at" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "group_epoch" (
    "id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1),
    "n" INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "groups" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "created_at" TEXT NOT NULL,
    "space_layer" INTEGER NOT NULL DEFAULT 1 CHECK ("space_layer" IN (0, 1)),
    "removed_at" TEXT
  );
  CREATE TABLE IF NOT EXISTS "group_members" (
    "grp" TEXT NOT NULL REFERENCES "groups" ("id"),
    "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
    "joined_at" TEXT NOT NULL,
    PRIMARY KEY ("grp", "account_id")
  );
  CREATE INDEX IF NOT EXISTS "group_members_by_account" ON "group_members" ("account_id");
  CREATE TABLE IF NOT EXISTS "group_edges" (
    "src" TEXT NOT NULL REFERENCES "groups" ("id"),
    "dst" TEXT NOT NULL REFERENCES "groups" ("id"),
    "kind" TEXT NOT NULL CHECK ("kind" IN ('read', 'admin')),
    "created_at" TEXT NOT NULL,
    "created_by" TEXT,
    PRIMARY KEY ("src", "dst", "kind")
  );
  CREATE TABLE IF NOT EXISTS "message_groups" (
    "message_id" TEXT NOT NULL PRIMARY KEY,
    "grp" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "session_space_layer" (
    "session_id" TEXT NOT NULL PRIMARY KEY,
    "space_layer" INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "group_reads" (
    "grp" TEXT NOT NULL,
    "readable" TEXT NOT NULL,
    "via" TEXT NOT NULL,
    PRIMARY KEY ("grp", "readable", "via")
  );
  INSERT OR IGNORE INTO "schema_compactions" ("name", "applied_at") VALUES ('wuhu-45', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
  INSERT OR IGNORE INTO "group_epoch" ("id", "n") VALUES (1, 1);
  INSERT OR IGNORE INTO "groups" ("id", "created_at") VALUES ('shared', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
  INSERT OR IGNORE INTO "group_reads" ("grp", "readable", "via") VALUES ('shared', 'shared', 'self');
  CREATE TABLE IF NOT EXISTS "devices" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
    "pubkey" TEXT NOT NULL UNIQUE,
    "installation" TEXT NOT NULL,
    "kind" TEXT NOT NULL CHECK ("kind" IN ('phone', 'pad', 'mac', 'vision', 'web')),
    "name" TEXT NOT NULL,
    "machine_id" TEXT REFERENCES "machines" ("id"),
    "created_at" TEXT NOT NULL,
    "last_seen_at" TEXT NOT NULL
  );
  CREATE UNIQUE INDEX IF NOT EXISTS "devices_by_installation" ON "devices" ("account_id", "installation");
  CREATE TABLE IF NOT EXISTS "device_commands" (
    "n" INTEGER PRIMARY KEY AUTOINCREMENT,
    "device_id" TEXT NOT NULL REFERENCES "devices" ("id"),
    "payload" TEXT NOT NULL,
    "issued_by" TEXT NOT NULL,
    "created_at" TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS "device_commands_by_device" ON "device_commands" ("device_id", "n");
  CREATE TABLE IF NOT EXISTS "message_devices" (
    "message_id" TEXT NOT NULL PRIMARY KEY,
    "device_id" TEXT NOT NULL REFERENCES "devices" ("id")
  );
  CREATE TABLE IF NOT EXISTS "message_viewing" (
    "message_id" TEXT NOT NULL PRIMARY KEY,
    "path" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "join_tokens" (
    "token_hash" TEXT NOT NULL PRIMARY KEY,
    "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
    "capabilities" TEXT NOT NULL,
    "created_by" TEXT REFERENCES "accounts" ("id"),
    "created_at" TEXT NOT NULL,
    "expires_at" TEXT NOT NULL,
    "grp" TEXT NOT NULL DEFAULT ''
  );
  CREATE TRIGGER IF NOT EXISTS "join_tokens_grp_required" BEFORE INSERT ON "join_tokens" WHEN NEW."grp" = ''
    BEGIN SELECT RAISE(ABORT, 'grp required: join_tokens'); END;
  CREATE INDEX IF NOT EXISTS "join_tokens_by_account" ON "join_tokens" ("account_id");
  -- What a consumed machine token enrolled, so the same token with the same pubkey
  -- replays to the same key: a box that lost the response retries instead of
  -- being locked out. A receipt dies with its key (rotation, revocation, kick)
  -- and is pruned once the token's own expiry passes.
  CREATE TABLE IF NOT EXISTS "join_token_receipts" (
    "token_hash" TEXT NOT NULL PRIMARY KEY,
    "pubkey" TEXT NOT NULL REFERENCES "account_keys" ("pubkey") ON DELETE CASCADE,
    "expires_at" TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS "join_token_receipts_by_pubkey" ON "join_token_receipts" ("pubkey");
  CREATE TABLE IF NOT EXISTS "personas" (
    "name" TEXT NOT NULL PRIMARY KEY,
    "allocation" INTEGER NOT NULL UNIQUE,
    "pubkey" TEXT NOT NULL,
    "account_id" TEXT NOT NULL REFERENCES "accounts" ("id"),
    "created_at" TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS "personas_by_account" ON "personas" ("account_id");
  CREATE TABLE IF NOT EXISTS "space_meta" (
    "id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1),
    "space_id" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "space_deployment" (
    "id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1),
    "origin" TEXT,
    "tls_fingerprint" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "space_deployment_certificate" (
    "id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1),
    "tls_fingerprint" TEXT NOT NULL,
    "generated" INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "web_push_subscriptions" (
    "endpoint" TEXT NOT NULL PRIMARY KEY,
    "recipient" TEXT NOT NULL REFERENCES "personas" ("name"),
    "device_pubkey" TEXT NOT NULL REFERENCES "account_keys" ("pubkey") ON DELETE CASCADE,
    "p256dh" TEXT NOT NULL,
    "auth" TEXT NOT NULL,
    "vapid_key_id" TEXT NOT NULL,
    "notification_cursor" INTEGER NOT NULL,
    "consecutive_failures" INTEGER NOT NULL DEFAULT 0,
    "retry_at" TEXT,
    "expires_at" TEXT,
    "created_at" TEXT NOT NULL,
    "updated_at" TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS "web_push_subscriptions_by_recipient"
    ON "web_push_subscriptions" ("recipient", "notification_cursor");
  CREATE INDEX IF NOT EXISTS "web_push_subscriptions_by_retry"
    ON "web_push_subscriptions" ("retry_at");
  CREATE TABLE IF NOT EXISTS "push_relay_grants" (
    "grant_id" TEXT NOT NULL PRIMARY KEY,
    "endpoint" TEXT NOT NULL,
    "token" TEXT NOT NULL,
    -- Carried only so a space created before the column was dropped from the
    -- model still satisfies its own NOT NULL. Nothing reads it.
    "platform" TEXT NOT NULL,
    "recipient" TEXT NOT NULL REFERENCES "personas" ("name"),
    "device_pubkey" TEXT NOT NULL REFERENCES "account_keys" ("pubkey") ON DELETE CASCADE,
    "notification_cursor" INTEGER NOT NULL,
    "consecutive_failures" INTEGER NOT NULL DEFAULT 0,
    "retry_at" TEXT,
    "created_at" TEXT NOT NULL,
    "updated_at" TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS "push_relay_grants_by_recipient"
    ON "push_relay_grants" ("recipient", "notification_cursor");
  CREATE INDEX IF NOT EXISTS "push_relay_grants_by_retry"
    ON "push_relay_grants" ("retry_at");
  CREATE TABLE IF NOT EXISTS "user_profiles" (
    "principal" TEXT NOT NULL PRIMARY KEY,
    "handle" TEXT NOT NULL UNIQUE,
    "display_name" TEXT,
    "updated_at" TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "session_prompt_revisions" (
    "session_id" TEXT NOT NULL PRIMARY KEY,
    "rev" INTEGER NOT NULL
  );
  CREATE TABLE IF NOT EXISTS "inferences" (
    "id" TEXT NOT NULL PRIMARY KEY,
    "session" TEXT NOT NULL,
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
    "grp" TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS "inferences_by_session_at" ON "inferences" ("session", "at");
  CREATE INDEX IF NOT EXISTS "inferences_by_grp_at" ON "inferences" ("grp", "at");
  CREATE INDEX IF NOT EXISTS "session_contents_assistant_history" ON "session_contents" ("session_id")
    WHERE json_type("payload", '$.assistant') IS NOT NULL;
  CREATE INDEX IF NOT EXISTS "session_pointers_by_content" ON "session_pointers" ("session_id", "generation", "content_id", "position");
  """
}
