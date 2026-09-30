import Foundation
import StructuredQueries
import StructuredQueriesSQLite

let spaceSchemaSQL = [
  substrateSchemaSQL, blobObjectSchemaSQL, sessionSchemaSQL, sessionCommandSchemaSQL, sessionContextSchemaSQL,
  sessionScopeContextSchemaSQL, conversationSchemaSQL, notificationSchemaSQL,
  allocationSchemaSQL, authSchemaSQL, groupSchemaSQL, deviceSchemaSQL, enrollmentSchemaSQL, personaSchemaSQL,
  claudeCodeSchemaSQL, claudeCodeHandoverSchemaSQL, spaceMetaSchemaSQL, webPushSchemaSQL, pushRelaySchemaSQL,
  userProfileSchemaSQL, sessionPromptRevisionSchemaSQL, inferenceSchemaSQL,
]
.joined(separator: "\n")

let substrateSchemaSQL = """
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
  "grp" TEXT NOT NULL DEFAULT ''
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
"""

@Table("revisions")
struct RevisionRow {
  @Column("rev", primaryKey: true) var rev: Int64
  @Column("mtime") var mtime: String
  @Column("grp") var grp: String
}

@Table("blobs")
struct BlobRow {
  @Column("hash", primaryKey: true) var hash: String
  @Column("content") var content: [UInt8]
}

@Table("fs_versions")
struct FSVersionRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("rev") var rev: Int64
  @Column("kind") var kind: String?
  @Column("blob_hash") var blobHash: String?
  @Column("op") var op: String
  @Column("aux") var aux: String?
}

@Table("fs_heads")
struct FSHeadRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("parent_path") var parentPath: String
  @Column("kind") var kind: String
  @Column("blob_hash") var blobHash: String?
  @Column("size") var size: Int64
  @Column("line_count") var lineCount: Int64?
  @Column("etag") var etag: String
  @Column("rev") var rev: Int64
  @Column("mtime") var mtime: String
}

@Table("docs")
struct DocRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("title") var title: String
  @Column("kind") var kind: String?
  @Column("status") var status: String?
}

@Table("links")
struct LinkRow {
  @Column("grp") var grp: String
  @Column("src") var src: String
  @Column("dst_grp") var dstGroup: String
  @Column("dst") var dst: String
}

@Table("doc_custom_attrs")
struct DocCustomAttrRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("name") var name: String
  @Column("ord") var ord: Int64
  @Column("value") var value: String
}

@Table("tables")
struct TableNodeRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("created_rev") var createdRev: Int64
}

@Table("table_schema_versions")
struct TableSchemaVersionRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("rev") var rev: Int64
  @Column("header_json") var headerJSON: String
}

@Table("table_rows")
struct TableRowRow {
  @Column("grp") var grp: String
  @Column("path") var path: String
  @Column("row_id") var rowID: Int64
  @Column("created_rev") var createdRev: Int64
  @Column("deleted_rev") var deletedRev: Int64?
  @Column("payload") var payload: String
}

@Table("machines")
struct MachineRow {
  @Column("id", primaryKey: true) var id: String
  @Column("account_id") var accountID: String
  @Column("name") var name: String?
  @Column("created_at") var createdAt: String
  @Column("grp") var grp: String
}

@Table("script_execs")
struct ScriptExecRow {
  @Column("exec_id", primaryKey: true) var execID: String
  @Column("script_id") var scriptID: String
  @Column("session_id") var sessionID: String
  @Column("grp") var grp: String
}
