// Kinds the code no longer knows leave what it reads: inbox rows move aside,
// a transcript's dead notices take the kind that always read the same way,
// and a generation head forgets its deadline subscriptions.
enum Migration025 {
  static func apply(_ db: MigrationDB) throws {
    try db.execute(sql: """
    CREATE TABLE notifications_retired AS SELECT * FROM notifications WHERE kind IN ('request_deadline', 'child_failed');
    DELETE FROM notifications WHERE kind IN ('request_deadline', 'child_failed');
    UPDATE session_queue SET payload = json_set(payload, '$.notification._0.kind', 'requestStall')
      WHERE payload LIKE '{"notification"%' AND json_extract(payload, '$.notification._0.kind') IN ('childFailed', 'requestDeadline');
    UPDATE session_contents SET payload = CASE WHEN payload LIKE '{"notification"%'
      THEN json_set(payload, '$.notification._0.kind', 'requestStall')
      ELSE json_set(payload, '$.generationHead._0.snapshot.subscriptions', json((
        SELECT '[' || coalesce(group_concat(json_quote(id.value) || ',' || subscription.value, ','), '') || ']'
        FROM json_each(session_contents.payload, '$.generationHead._0.snapshot.subscriptions') id
        JOIN json_each(session_contents.payload, '$.generationHead._0.snapshot.subscriptions') subscription ON subscription.key = id.key + 1
        WHERE id.key % 2 = 0 AND CASE subscription.type WHEN 'object' THEN json_type(subscription.value, '$.requestDeadline') END IS NULL
      ))) END
      WHERE CASE WHEN payload LIKE '{"notification"%' THEN json_extract(payload, '$.notification._0.kind') IN ('childFailed', 'requestDeadline')
        WHEN payload LIKE '{"generationHead"%' THEN payload LIKE '%"requestDeadline"%' END;
    """)
  }
}
