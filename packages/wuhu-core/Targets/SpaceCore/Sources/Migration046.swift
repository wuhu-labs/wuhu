import GRDB

enum Migration046 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    ALTER TABLE revisions RENAME TO revisions_old;
    ALTER TABLE revision_actors RENAME TO revision_actors_old;
    CREATE TABLE revisions (
      grp TEXT NOT NULL, rev INTEGER NOT NULL, mtime TEXT NOT NULL, PRIMARY KEY (grp, rev)
    );
    CREATE TABLE revision_actors (
      grp TEXT NOT NULL, rev INTEGER NOT NULL, actor TEXT, via TEXT NOT NULL, PRIMARY KEY (grp, rev)
    );
    INSERT INTO revisions (grp, rev, mtime)
    SELECT DISTINCT v.grp, v.rev, r.mtime FROM fs_versions v JOIN revisions_old r ON r.rev = v.rev;
    INSERT OR IGNORE INTO revisions (grp, rev, mtime)
    SELECT g.id, r.rev, r.mtime FROM groups g JOIN revisions_old r ON r.rev = (SELECT MAX(rev) FROM revisions_old);
    INSERT INTO revision_actors (grp, rev, actor, via)
    SELECT DISTINCT v.grp, v.rev, a.actor, a.via FROM fs_versions v JOIN revision_actors_old a ON a.rev = v.rev;
    ALTER TABLE session_prompts RENAME TO session_prompts_old;
    CREATE TABLE session_prompts (
      session_id TEXT NOT NULL PRIMARY KEY, generation INTEGER NOT NULL, revs TEXT NOT NULL,
      rendered TEXT, session TEXT, CHECK ((rendered IS NULL) = (session IS NULL))
    );
    INSERT INTO session_prompts (session_id, generation, revs, rendered, session)
    SELECT session_id, generation, (SELECT json_group_object(id, p.rev) FROM groups), rendered, session FROM session_prompts_old p;
    DROP TABLE session_prompts_old;
    DROP TABLE revision_actors_old;
    DROP TABLE revisions_old;
    CREATE INDEX revision_actors_by_via ON revision_actors (via);
    """)
  }
}
