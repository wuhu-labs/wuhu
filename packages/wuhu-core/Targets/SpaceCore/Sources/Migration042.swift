import GRDB

enum Migration042 {
  static func apply(_ db: Database) throws {
    try db.execute(sql: """
    DELETE FROM session_model_routes
    WHERE group_id IS NULL AND EXISTS (
      SELECT 1 FROM sessions
      WHERE sessions.id = session_model_routes.session_id
        AND (
          sessions.executor <> 'kernel'
          OR json_extract(session_model_routes.payload, '$.specifier.provider') IS NOT json_extract(sessions.executor_config, '$.provider')
          OR json_extract(session_model_routes.payload, '$.specifier.model') IS NOT json_extract(sessions.executor_config, '$.model')
          OR json_extract(session_model_routes.payload, '$.specifier.effort') IS NOT json_extract(sessions.executor_config, '$.effort')
        )
    );
    DROP TABLE session_receipts;
    DROP TABLE session_api_receipts;
    """)
  }
}
