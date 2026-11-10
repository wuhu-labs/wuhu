import GRDB

enum Migration017 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    CREATE TABLE wuwei_addressable (
      id INTEGER PRIMARY KEY, address TEXT NOT NULL UNIQUE,
      holder TEXT NOT NULL, fence INTEGER NOT NULL, expires_at INTEGER NOT NULL, page_count INTEGER NOT NULL DEFAULT 0, wake_at INTEGER);
    CREATE TABLE wuwei_mail (id INTEGER PRIMARY KEY AUTOINCREMENT, recipient TEXT NOT NULL, payload BLOB NOT NULL);
    CREATE INDEX wuwei_mail_recipient ON wuwei_mail (recipient);
    CREATE TABLE wuwei_job (address TEXT PRIMARY KEY, params BLOB NOT NULL, phase TEXT NOT NULL DEFAULT 'new', wake_at INTEGER);
    CREATE TABLE wuwei_schema (kind TEXT PRIMARY KEY, applied INTEGER NOT NULL);
    """)
  }
}
