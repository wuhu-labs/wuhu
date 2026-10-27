import GRDB

// A session's prompt is rendered once per generation and stored: the
// generation and the revision it reads files at, and once rendered, its text
// and the session its templates saw. Older binaries never stored the text, so
// sessions mid-generation at the 007 upgrade re-render once; after it, an
// upgrade never re-renders a stored prompt.
enum Migration007 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    CREATE TABLE "session_prompts" (
      "session_id" TEXT NOT NULL PRIMARY KEY,
      "generation" INTEGER NOT NULL,
      "rev" INTEGER NOT NULL,
      "prompt" TEXT,
      "session" TEXT,
      CHECK (("prompt" IS NULL) = ("session" IS NULL))
    );
    INSERT INTO "session_prompts" ("session_id", "generation", "rev")
      SELECT p."session_id", COALESCE(r."generation", 0), p."rev"
      FROM "session_prompt_revisions" p LEFT JOIN "session_runtime" r ON r."session_id" = p."session_id";
    DROP TABLE "session_prompt_revisions";
    """)
  }
}
