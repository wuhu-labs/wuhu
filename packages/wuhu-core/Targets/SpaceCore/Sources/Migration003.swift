import GRDB

/// The settings group, the admin table, personal groups, and the end of the
/// space-wide layer. Self-contained by rule: raw SQL and local code.
enum Migration003 {
  /// The documents the space's settings live in, copied once from `shared` and
  /// deleted there as ordinary file deletes, so the journal keeps them.
  private static let settingsDocuments = [
    "/models.json", "/model-groups.json", "/capabilities.json", "/machine-v2-upgrade.json",
  ]

  static func apply(_ db: Database) throws {
    try db.execute(sql: "ALTER TABLE groups ADD COLUMN personal_account TEXT REFERENCES accounts(id)")
    try db.execute(sql: "CREATE UNIQUE INDEX groups_personal_account ON groups(personal_account)")
    try db.execute(sql: """
    UPDATE groups SET personal_account = (
      SELECT m.account_id FROM group_members m
      JOIN group_edges e ON e.src = m.grp AND e.dst = m.grp AND e.kind = 'admin'
      WHERE m.grp = groups.id ORDER BY m.joined_at, m.account_id LIMIT 1
    )
    WHERE id != 'shared' AND id IN (
      SELECT m.grp FROM group_members m
      JOIN accounts a ON a.id = m.account_id AND a.kind = 'human' AND a.removed_at IS NULL
      JOIN group_edges e ON e.src = m.grp AND e.dst = m.grp AND e.kind = 'admin'
      WHERE (SELECT count(*) FROM group_members n WHERE n.grp = m.grp) = 1
        AND m.grp = (
          SELECT n.grp FROM group_members n JOIN group_edges e ON e.src = n.grp AND e.dst = n.grp AND e.kind = 'admin'
          WHERE n.account_id = m.account_id ORDER BY n.joined_at, n.grp LIMIT 1
        )
    );
    INSERT INTO groups (id, created_at) VALUES ('settings', strftime('%Y-%m-%dT%H:%M:%fZ', 'now'));
    CREATE TABLE group_roles (
      account_id TEXT NOT NULL REFERENCES accounts(id),
      grp TEXT NOT NULL REFERENCES groups(id),
      role TEXT NOT NULL,
      created_at TEXT NOT NULL,
      PRIMARY KEY (account_id, grp)
    );
    """)

    // Admins carry over: the members of a self-administered group administer
    // it, and whoever administered `shared` is a space admin.
    try db.execute(sql: """
    INSERT INTO group_roles (account_id, grp, role, created_at)
      SELECT DISTINCT m.account_id, CASE WHEN e.dst = 'shared' THEN 'settings' ELSE e.dst END, 'admin',
        strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
      FROM group_members m
      JOIN accounts a ON a.id = m.account_id AND a.kind = 'human' AND a.removed_at IS NULL
      JOIN group_edges s ON s.src = m.grp AND s.dst = m.grp AND s.kind = 'admin'
      JOIN group_edges e ON e.src = m.grp AND e.kind = 'admin'
      WHERE e.dst NOT IN (SELECT id FROM groups WHERE personal_account IS NOT NULL)
    """)
    try db.execute(sql: """
    INSERT INTO group_roles (account_id, grp, role, created_at)
      SELECT g.personal_account, g.id, 'admin', strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
      FROM groups g JOIN accounts a ON a.id = g.personal_account AND a.removed_at IS NULL
      WHERE g.personal_account IS NOT NULL
    """)

    // Layering ends: the edges that only granted admin, a personal group's
    // incoming read edges, the per-session choice and the per-group switch.
    try db.execute(sql: "DELETE FROM group_edges WHERE kind = 'admin'")
    try db.execute(sql: """
    DELETE FROM group_edges
      WHERE dst IN (SELECT id FROM groups WHERE personal_account IS NOT NULL) AND src != dst
    """)
    try db.execute(sql: """
    CREATE TABLE group_edges_new (
      src TEXT NOT NULL REFERENCES groups(id), dst TEXT NOT NULL REFERENCES groups(id),
      kind TEXT NOT NULL CHECK (kind = 'read'), created_at TEXT NOT NULL, created_by TEXT,
      PRIMARY KEY (src, dst, kind)
    )
    """)
    try db.execute(sql: "INSERT INTO group_edges_new SELECT src, dst, kind, created_at, created_by FROM group_edges")
    try db.execute(sql: "DROP TABLE group_edges")
    try db.execute(sql: "ALTER TABLE group_edges_new RENAME TO group_edges")
    try db.execute(sql: "DROP TABLE session_space_layer")
    try db.execute(sql: "ALTER TABLE groups DROP COLUMN space_layer")
    try rebuildReads(db)

    for path in settingsDocuments {
      try copySettingsDocument(path, in: db)
    }
  }

  /// Rebuilds `group_reads` from the remaining read edges, dropping rows no
  /// edge justifies, and bumps the epoch.
  private static func rebuildReads(_ db: Database) throws {
    let groups = try String.fetchAll(db, sql: "SELECT id FROM groups ORDER BY id")
    var edges: [String: [String]] = [:]
    for row in try Row.fetchAll(db, sql: "SELECT src, dst FROM group_edges ORDER BY src, dst") {
      edges[row["src"], default: []].append(row["dst"])
    }
    try db.execute(sql: "DELETE FROM group_reads")
    for group in groups {
      try db.execute(sql: "INSERT INTO group_reads (grp, readable, via) VALUES (?, ?, 'self')", arguments: [group, group])
      for hop in edges[group, default: []] {
        var seen: Set<String> = [hop]
        var queue = [hop]
        while let next = queue.popLast() {
          if next != group {
            try db.execute(
              sql: "INSERT OR IGNORE INTO group_reads (grp, readable, via) VALUES (?, ?, ?)",
              arguments: [group, next, "\(group)->\(hop)"],
            )
          }
          for further in edges[next, default: []] where seen.insert(further).inserted {
            queue.append(further)
          }
        }
      }
    }
    try db.execute(sql: "UPDATE group_epoch SET n = n + 1 WHERE id = 1")
  }

  /// `path`'s file from `shared` as a blob, a revision, a version and a head
  /// row in the settings group, then deleted from `shared` as an ordinary file
  /// delete. Both revisions are stamped now, so the journal only moves forward;
  /// the settings head keeps the file's own mtime. A path `shared` does not
  /// have is skipped.
  private static func copySettingsDocument(_ path: String, in db: Database) throws {
    guard let head = try Row.fetchOne(
      db,
      sql: "SELECT blob_hash, size, line_count, etag, mtime FROM fs_heads WHERE grp = 'shared' AND path = ? AND kind = 'file'",
      arguments: [path],
    ), let hash: String = head["blob_hash"], let mtime: String = head["mtime"]
    else { return }
    let now = try String.fetchOne(db, sql: "SELECT strftime('%Y-%m-%dT%H:%M:%fZ', 'now')") ?? mtime
    try db.execute(sql: "INSERT INTO revisions (mtime, grp) VALUES (?, 'settings')", arguments: [now])
    let written = db.lastInsertedRowID
    try db.execute(
      sql: "INSERT INTO fs_versions (grp, path, rev, kind, blob_hash, op, aux) VALUES ('settings', ?, ?, 'file', ?, 'write', NULL)",
      arguments: [path, written, hash],
    )
    try db.execute(
      sql: """
      INSERT INTO fs_heads (grp, path, parent_path, kind, blob_hash, size, line_count, etag, rev, mtime)
      VALUES ('settings', ?, '/', 'file', ?, ?, ?, ?, ?, ?)
      """,
      arguments: [path, hash, head["size"], head["line_count"], head["etag"], written, mtime],
    )
    try db.execute(sql: "INSERT INTO revisions (mtime, grp) VALUES (?, 'shared')", arguments: [now])
    let deleted = db.lastInsertedRowID
    try db.execute(
      sql: "INSERT INTO fs_versions (grp, path, rev, kind, blob_hash, op, aux) VALUES ('shared', ?, ?, NULL, NULL, 'delete', NULL)",
      arguments: [path, deleted],
    )
    try db.execute(sql: "DELETE FROM fs_heads WHERE grp = 'shared' AND path = ?", arguments: [path])
  }
}
