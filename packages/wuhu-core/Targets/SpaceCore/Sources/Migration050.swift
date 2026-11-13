// wuwei's housekeeping scan asks for the jobs not yet done and the addressables with a wake due; without these
// it walks every finished job and every addressable each time.
enum Migration050 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    CREATE INDEX wuwei_job_pending ON wuwei_job (address, wake_at) WHERE phase != 'done';
    CREATE INDEX wuwei_addressable_wake ON wuwei_addressable (wake_at) WHERE wake_at IS NOT NULL;
    """)
  }
}
