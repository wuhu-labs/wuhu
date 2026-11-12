import GRDB

enum Migration035 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    INSERT INTO wuwei_mail (recipient, payload)
    SELECT DISTINCT 'SessionCell/' || owner, CAST('{"rewatch":{}}' AS BLOB)
    FROM subscription_slots
    WHERE owner_kind = 'session' AND status = 'armed'
      AND ((json_type(payload, '$.kind.observe') IS NOT NULL AND json_extract(payload, '$.handler') IS NULL)
        OR json_type(payload, '$.kind.children') IS NOT NULL);

    INSERT INTO wuwei_mail (recipient, payload)
    SELECT 'ObserverCell/' || owner_kind || ':' || owner || ':' || subscription_id, CAST('{"look":{}}' AS BLOB)
    FROM subscription_slots
    WHERE status = 'armed' AND json_type(payload, '$.kind.observe') IS NOT NULL
      AND json_extract(payload, '$.handler') IS NOT NULL;
    """)
  }
}
