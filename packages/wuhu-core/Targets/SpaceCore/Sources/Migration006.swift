#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB

// A permanent reservation is also the redirect: renaming never frees a spelling.
enum Migration006 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    ALTER TABLE groups ADD COLUMN alias TEXT;
    CREATE TABLE aliases (
      name TEXT PRIMARY KEY COLLATE NOCASE,
      kind TEXT NOT NULL CHECK (kind IN ('group', 'person', 'machine')),
      target TEXT NOT NULL
    );
    """)
    struct Label {
      let kind: String
      let table: String
      let key: String
      let column: String
      let id: String
      let old: String
    }
    var labels: [Label] = []
    let people = try Row.fetchAll(db, sql: "SELECT principal, handle FROM user_profiles ORDER BY principal").map {
      Label(kind: "person", table: "user_profiles", key: "principal", column: "handle", id: $0["principal"], old: $0["handle"])
    }
    var liveMachines = 0
    for row in try Row.fetchAll(db, sql: """
    SELECT id, name, EXISTS (SELECT 1 FROM account_keys WHERE account_id = machines.account_id AND (expires_at IS NULL OR expires_at > strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))) AS live
    FROM machines WHERE name IS NOT NULL ORDER BY live DESC, created_at, id
    """) {
      labels.append(Label(kind: "machine", table: "machines", key: "id", column: "name", id: row["id"], old: row["name"]))
      if row["live"] as Bool { liveMachines += 1 }
    }
    labels.insert(contentsOf: people, at: liveMachines)
    for row in try Row.fetchAll(db, sql: "SELECT id FROM groups WHERE personal_account IS NULL ORDER BY CASE id WHEN 'shared' THEN 0 ELSE 1 END, id") {
      let id: String = row["id"]
      let label = Label(kind: "group", table: "groups", key: "id", column: "alias", id: id, old: id)
      if id == "shared" { labels.insert(label, at: 0) }
      else { labels.append(label) }
    }
    // Existing per-table unique constraints must not observe intermediate collisions.
    for (index, label) in labels.enumerated() {
      try db.execute(sql: "UPDATE \(label.table) SET \(label.column) = ? WHERE \(label.key) = ?", arguments: ["__migration006_\(index)", label.id])
    }
    let groupIDs = Set(try String.fetchAll(db, sql: "SELECT lower(id) FROM groups"))
    var occupied = Set<String>()
    for label in labels {
      let limit = label.kind == "person" ? 32 : 63
      let base = sanitized(label.old, limit: limit)
      var alias = base
      var suffix = 0
      while occupied.contains(alias) || (groupIDs.contains(alias) && !(label.kind == "group" && alias == label.id.lowercased())) {
        suffix += 1
        let ending = "_\(suffix)"
        alias = String(base.prefix(limit - ending.count)) + ending
      }
      occupied.insert(alias)
      try db.execute(sql: "INSERT INTO aliases VALUES (?, ?, ?)", arguments: [alias, label.kind, label.id])
      try db.execute(sql: "UPDATE \(label.table) SET \(label.column) = ? WHERE \(label.key) = ?", arguments: [alias, label.id])
      if label.kind == "machine" {
        try db.execute(sql: "UPDATE accounts SET name = ? WHERE id = (SELECT account_id FROM machines WHERE id = ?)", arguments: [alias, label.id])
      }
      if occupied.insert(label.old.lowercased()).inserted {
        try db.execute(sql: "INSERT INTO aliases VALUES (?, ?, ?)", arguments: [label.old.lowercased(), label.kind, label.id])
      }
    }
    for (table, key, column, kind) in [("groups", "id", "alias", "group"), ("user_profiles", "principal", "handle", "person"), ("machines", "id", "name", "machine")] {
      for event in ["INSERT", "UPDATE OF \(column)"] {
        let suffix = event == "INSERT" ? "insert" : "update"
        try db.execute(sql: """
        CREATE TRIGGER \(table)_alias_\(suffix) AFTER \(event) ON \(table)
        WHEN NEW.\(column) IS NOT NULL
        BEGIN
          SELECT RAISE(ABORT, 'aliasTaken') WHERE EXISTS (
            SELECT 1 FROM aliases WHERE name = NEW.\(column)
              AND (kind != '\(kind)' OR target != NEW.\(key))
          );
          INSERT INTO aliases (name, kind, target) VALUES (NEW.\(column), '\(kind)', NEW.\(key))
            ON CONFLICT(name) DO NOTHING;
        END;
        """)
      }
    }
  }

  private static func sanitized(_ raw: String, limit: Int) -> String {
    var result = ""
    for scalar in raw.lowercased().unicodeScalars {
      let kept = ("a" ... "z").contains(scalar) || ("0" ... "9").contains(scalar) || scalar == "_" || scalar == "."
      result.unicodeScalars.append(kept ? scalar : "_")
    }
    if result.first.map({ !(($0.isASCII && $0.isLetter) || $0.isNumber) }) ?? true { result = "m" + result }
    result = String(result.prefix(limit))
    return result
  }
}
