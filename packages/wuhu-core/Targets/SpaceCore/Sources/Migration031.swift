import GRDB

// The journal's copies, in every group, of the attachments that migration 029 made rows of: files, folders, their versions and what was induced from them. The revisions that wrote them stay, so no revision number is reused; the blobs stay, named by `attachments.blob`.
enum Migration031 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    DELETE FROM fs_heads WHERE path GLOB '/_/conversations' OR path GLOB '/_/conversations/*';
    DELETE FROM fs_versions WHERE path GLOB '/_/conversations' OR path GLOB '/_/conversations/*';
    DELETE FROM docs WHERE path GLOB '/_/conversations/*';
    DELETE FROM links WHERE src GLOB '/_/conversations/*';
    DELETE FROM doc_custom_attrs WHERE path GLOB '/_/conversations/*';
    """)
  }
}
