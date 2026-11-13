import GRDB

/// The bucket: one row per hash, inline bytes or an object key, grow-only. It replaces `blobs` and
/// `blob_objects`, which held the two cases apart; an inline row keeps its line count unrecorded, counted
/// from its bytes when asked.
enum Migration045 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    CREATE TABLE "bucket_objects" (
      "hash" TEXT NOT NULL PRIMARY KEY,
      "size" INTEGER NOT NULL,
      "line_count" INTEGER,
      "content" BLOB,
      "object_key" TEXT,
      "stored_at" TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
      CHECK (("content" IS NULL) <> ("object_key" IS NULL))
    );
    INSERT INTO "bucket_objects" ("hash", "size", "line_count", "content", "object_key")
      SELECT "hash", "size", "line_count", NULL, "object_key" FROM "blob_objects";
    INSERT OR IGNORE INTO "bucket_objects" ("hash", "size", "line_count", "content", "object_key")
      SELECT "hash", length("content"), NULL, "content", NULL FROM "blobs";
    DROP TABLE "blob_objects";
    DROP TABLE "blobs";
    """)
  }
}
