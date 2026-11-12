import GRDB

enum Migration040 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    ALTER TABLE wuwei_job ADD COLUMN creator TEXT;
    ALTER TABLE wuwei_mail ADD COLUMN lifecycle TEXT;
    UPDATE wuwei_job
    SET creator = 'SessionCell/' || substr(address, length('InferenceJob/') + 1, instr(address, ':') - length('InferenceJob/') - 1)
    WHERE address LIKE 'InferenceJob/%' AND phase != 'done' AND creator IS NULL;
    """)
  }
}
