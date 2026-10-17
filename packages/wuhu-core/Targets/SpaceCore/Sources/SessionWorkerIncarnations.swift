let sessionWorkerSchemaSQL = """
CREATE TABLE IF NOT EXISTS "session_worker_incarnations" (
  "session_id" TEXT NOT NULL REFERENCES "sessions" ("id") ON DELETE CASCADE,
  "incarnation" TEXT NOT NULL,
  "died_at" REAL,
  PRIMARY KEY ("session_id", "incarnation")
);
"""
