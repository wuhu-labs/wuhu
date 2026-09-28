.bail on
-- Groups: the one-way compaction of a pre-groups space database.
-- Run with the server stopped, after PRAGMA wal_checkpoint(TRUNCATE): `sqlite3 space.sqlite < this-file`.
-- `.bail on` above stops at the first error with the transaction uncommitted, so the file is left as it was.
-- Before running, splice the user-table renames over the @@USER_TABLE_RENAMES@@ line (see there).
-- A new binary refuses a file without the 'wuhu-45' row; on its first serve it re-induces docs, links
-- and attrs, and records 'wuhu-45-links'.
PRAGMA foreign_keys = OFF;
BEGIN IMMEDIATE;

CREATE TABLE schema_compactions ("name" TEXT NOT NULL PRIMARY KEY, "applied_at" TEXT NOT NULL);
INSERT INTO schema_compactions VALUES ('wuhu-45', strftime('%Y-%m-%dT%H:%M:%fZ','now'));
CREATE TABLE group_epoch ("id" INTEGER NOT NULL PRIMARY KEY CHECK ("id" = 1), "n" INTEGER NOT NULL);
INSERT INTO group_epoch VALUES (1, 1);

-- Every live admin account keeps admin through its personal group, so each must be a human with a persona.
CREATE TEMP TABLE wuhu45_guard ("admins_without_personal_group" INTEGER NOT NULL CHECK ("admins_without_personal_group" = 0));
INSERT INTO wuhu45_guard
SELECT count(*) FROM accounts a
WHERE a.is_admin = 1 AND a.removed_at IS NULL
  AND (a.kind <> 'human' OR NOT EXISTS (SELECT 1 FROM personas p WHERE p.account_id = a.id));
DROP TABLE wuhu45_guard;

-- Groups. No personal/shared flag. id: 'shared' or a three-word id (a personal group's is its person's).
CREATE TABLE groups (
  "id" TEXT NOT NULL PRIMARY KEY,
  "created_at" TEXT NOT NULL,
  "space_layer" INTEGER NOT NULL DEFAULT 1 CHECK ("space_layer" IN (0, 1)),
  "removed_at" TEXT
);
CREATE TABLE group_members (
  "grp" TEXT NOT NULL REFERENCES groups ("id"),
  "account_id" TEXT NOT NULL REFERENCES accounts ("id"),
  "joined_at" TEXT NOT NULL,
  PRIMARY KEY ("grp", "account_id")
);
CREATE INDEX group_members_by_account ON group_members ("account_id");
CREATE TABLE group_edges (
  "src" TEXT NOT NULL REFERENCES groups ("id"),
  "dst" TEXT NOT NULL REFERENCES groups ("id"),
  "kind" TEXT NOT NULL CHECK ("kind" IN ('read', 'admin')),
  "created_at" TEXT NOT NULL,
  "created_by" TEXT,
  PRIMARY KEY ("src", "dst", "kind")
);
CREATE TABLE group_reads (
  "grp" TEXT NOT NULL,
  "readable" TEXT NOT NULL,
  "via" TEXT NOT NULL,
  PRIMARY KEY ("grp", "readable", "via")
);
-- The group a message was posted from, one row per message posted after this; older rows fall back
-- to the sender session's group, else the conversation's.
CREATE TABLE message_groups ("message_id" TEXT NOT NULL PRIMARY KEY, "grp" TEXT NOT NULL);
-- Whether a session's frozen prompt carries the space-wide layer, taken with its prompt revision.
CREATE TABLE session_space_layer ("session_id" TEXT NOT NULL PRIMARY KEY, "space_layer" INTEGER NOT NULL);

INSERT INTO groups ("id", "created_at") VALUES ('shared', strftime('%Y-%m-%dT%H:%M:%fZ','now'));
-- One personal group per live human account with a persona, named after its earliest persona.
INSERT INTO groups ("id", "created_at")
SELECT p.name, a.created_at
FROM accounts a JOIN personas p ON p.account_id = a.id
WHERE a.kind = 'human' AND a.removed_at IS NULL
  AND p.allocation = (SELECT MIN(q.allocation) FROM personas q WHERE q.account_id = a.id);

-- Memberships: every live person is a member of shared, and of their personal group.
INSERT INTO group_members
SELECT 'shared', a.id, a.created_at FROM accounts a WHERE a.kind = 'human' AND a.removed_at IS NULL;
INSERT INTO group_members
SELECT g.id, p.account_id, g.created_at FROM groups g JOIN personas p ON p.name = g.id;

-- Read edges: a personal group reads shared.
INSERT INTO group_edges ("src", "dst", "kind", "created_at")
SELECT id, 'shared', 'read', created_at FROM groups WHERE id <> 'shared';
-- Admin edges: a person is a human admin of their own group, and every admin account of shared.
INSERT INTO group_edges ("src", "dst", "kind", "created_at")
SELECT id, id, 'admin', created_at FROM groups WHERE id <> 'shared';
INSERT INTO group_edges ("src", "dst", "kind", "created_at")
SELECT g.id, 'shared', 'admin', strftime('%Y-%m-%dT%H:%M:%fZ','now')
FROM groups g JOIN personas p ON p.name = g.id JOIN accounts a ON a.id = p.account_id
WHERE a.is_admin = 1;

INSERT INTO group_reads SELECT id, id, 'self' FROM groups;
INSERT INTO group_reads SELECT src, dst, src || '->' || dst FROM group_edges WHERE kind = 'read';

ALTER TABLE accounts DROP COLUMN is_admin;

-- A read session binds the web host it was minted on; NULL is shared.
ALTER TABLE read_sessions ADD COLUMN "grp" TEXT;

-- grp on tables that keep their keys. '' + trigger: a writer that forgets grp fails instead of landing in shared.
ALTER TABLE revisions     ADD COLUMN "grp" TEXT NOT NULL DEFAULT '';
ALTER TABLE sessions      ADD COLUMN "grp" TEXT NOT NULL DEFAULT '';
ALTER TABLE conversations ADD COLUMN "grp" TEXT NOT NULL DEFAULT '';
ALTER TABLE notifications ADD COLUMN "grp" TEXT NOT NULL DEFAULT '';
ALTER TABLE machines      ADD COLUMN "grp" TEXT NOT NULL DEFAULT '';
ALTER TABLE machine_execs ADD COLUMN "grp" TEXT NOT NULL DEFAULT '';
ALTER TABLE script_execs  ADD COLUMN "grp" TEXT NOT NULL DEFAULT '';
ALTER TABLE join_tokens   ADD COLUMN "grp" TEXT NOT NULL DEFAULT '';
UPDATE revisions SET grp = 'shared';
UPDATE sessions SET grp = 'shared';
UPDATE conversations SET grp = 'shared';
UPDATE notifications SET grp = 'shared';
UPDATE machines SET grp = 'shared';
UPDATE machine_execs SET grp = 'shared';
UPDATE script_execs SET grp = 'shared';
UPDATE join_tokens SET grp = 'shared';
CREATE TRIGGER revisions_grp_required BEFORE INSERT ON revisions WHEN NEW.grp = '' BEGIN SELECT RAISE(ABORT, 'grp required: revisions'); END;
CREATE TRIGGER sessions_grp_required BEFORE INSERT ON sessions WHEN NEW.grp = '' BEGIN SELECT RAISE(ABORT, 'grp required: sessions'); END;
CREATE TRIGGER conversations_grp_required BEFORE INSERT ON conversations WHEN NEW.grp = '' BEGIN SELECT RAISE(ABORT, 'grp required: conversations'); END;
CREATE TRIGGER notifications_grp_required BEFORE INSERT ON notifications WHEN NEW.grp = '' BEGIN SELECT RAISE(ABORT, 'grp required: notifications'); END;
CREATE TRIGGER machines_grp_required BEFORE INSERT ON machines WHEN NEW.grp = '' BEGIN SELECT RAISE(ABORT, 'grp required: machines'); END;
CREATE TRIGGER machine_execs_grp_required BEFORE INSERT ON machine_execs WHEN NEW.grp = '' BEGIN SELECT RAISE(ABORT, 'grp required: machine_execs'); END;
CREATE TRIGGER script_execs_grp_required BEFORE INSERT ON script_execs WHEN NEW.grp = '' BEGIN SELECT RAISE(ABORT, 'grp required: script_execs'); END;
CREATE TRIGGER join_tokens_grp_required BEFORE INSERT ON join_tokens WHEN NEW.grp = '' BEGIN SELECT RAISE(ABORT, 'grp required: join_tokens'); END;
CREATE INDEX sessions_by_grp ON sessions ("grp", "last_activity_at");
CREATE INDEX conversations_by_grp ON conversations ("grp");
CREATE INDEX notifications_by_grp ON notifications ("recipient", "grp", "n");

-- Path-keyed tables rebuilt with grp in the key (no default).
CREATE TABLE fs_versions_new (
  "grp" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "rev" INTEGER NOT NULL,
  "kind" TEXT,
  "blob_hash" TEXT,
  "op" TEXT NOT NULL,
  "aux" TEXT,
  PRIMARY KEY ("grp", "path", "rev")
);
INSERT INTO fs_versions_new SELECT 'shared', path, rev, kind, blob_hash, op, aux FROM fs_versions;
DROP TABLE fs_versions;
ALTER TABLE fs_versions_new RENAME TO fs_versions;
CREATE INDEX fs_versions_by_grp_rev ON fs_versions ("grp", "rev");

CREATE TABLE fs_heads_new (
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
INSERT INTO fs_heads_new SELECT 'shared', path, parent_path, kind, blob_hash, size, line_count, etag, rev, mtime FROM fs_heads;
DROP TABLE fs_heads;
ALTER TABLE fs_heads_new RENAME TO fs_heads;
CREATE INDEX fs_heads_by_grp_parent ON fs_heads ("grp", "parent_path");

CREATE TABLE docs_new (
  "grp" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "title" TEXT NOT NULL,
  "kind" TEXT,
  "status" TEXT,
  PRIMARY KEY ("grp", "path")
);
INSERT INTO docs_new SELECT 'shared', path, title, kind, status FROM docs;
DROP TABLE docs;
ALTER TABLE docs_new RENAME TO docs;

CREATE TABLE links_new (
  "grp" TEXT NOT NULL,
  "src" TEXT NOT NULL,
  "dst_grp" TEXT NOT NULL,
  "dst" TEXT NOT NULL,
  PRIMARY KEY ("grp", "src", "dst_grp", "dst")
);
INSERT INTO links_new SELECT 'shared', src, 'shared', dst FROM links;
DROP TABLE links;
ALTER TABLE links_new RENAME TO links;
CREATE INDEX links_by_dst ON links ("dst_grp", "dst");

CREATE TABLE doc_custom_attrs_new (
  "grp" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "name" TEXT NOT NULL,
  "ord" INTEGER NOT NULL,
  "value" TEXT NOT NULL,
  PRIMARY KEY ("grp", "path", "name", "ord")
);
INSERT INTO doc_custom_attrs_new SELECT 'shared', path, name, ord, value FROM doc_custom_attrs;
DROP TABLE doc_custom_attrs;
ALTER TABLE doc_custom_attrs_new RENAME TO doc_custom_attrs;

CREATE TABLE tables_new (
  "grp" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "created_rev" INTEGER NOT NULL,
  PRIMARY KEY ("grp", "path")
);
INSERT INTO tables_new SELECT 'shared', path, created_rev FROM tables;
DROP TABLE tables;
ALTER TABLE tables_new RENAME TO tables;

CREATE TABLE table_schema_versions_new (
  "grp" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "rev" INTEGER NOT NULL,
  "header_json" TEXT NOT NULL,
  PRIMARY KEY ("grp", "path", "rev")
);
INSERT INTO table_schema_versions_new SELECT 'shared', path, rev, header_json FROM table_schema_versions;
DROP TABLE table_schema_versions;
ALTER TABLE table_schema_versions_new RENAME TO table_schema_versions;

CREATE TABLE table_rows_new (
  "grp" TEXT NOT NULL,
  "path" TEXT NOT NULL,
  "row_id" INTEGER NOT NULL,
  "created_rev" INTEGER NOT NULL,
  "deleted_rev" INTEGER,
  "payload" TEXT NOT NULL,
  PRIMARY KEY ("grp", "path", "row_id", "created_rev")
);
INSERT INTO table_rows_new SELECT 'shared', path, row_id, created_rev, deleted_rev, payload FROM table_rows;
DROP TABLE table_rows;
ALTER TABLE table_rows_new RENAME TO table_rows;

-- User tables "/x.table" -> "shared:/x.table". Generated from the pre-migration file and spliced over the next line:
--   sqlite3 pre.sqlite "SELECT 'ALTER TABLE \"' || replace(path,'\"','\"\"') || '\" RENAME TO \"shared:' || replace(path,'\"','\"\"') || '\";' FROM tables ORDER BY path"
-- @@USER_TABLE_RENAMES@@

-- Prompt scopes re-resolve under shared.
DELETE FROM session_scope_context;

-- Poison pill: an old binary's schema script runs CREATE INDEX IF NOT EXISTS "fs_heads_by_parent";
-- a TABLE with that name makes it fail at open instead of serving unscoped data.
CREATE TABLE "fs_heads_by_parent" ("wuhu45" INTEGER);

COMMIT;
PRAGMA foreign_keys = ON;
PRAGMA foreign_key_check;
PRAGMA integrity_check;
