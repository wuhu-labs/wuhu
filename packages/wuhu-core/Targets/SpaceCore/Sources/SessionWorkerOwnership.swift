let sessionWorkerOwnershipSchemaSQL = """
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
"""
