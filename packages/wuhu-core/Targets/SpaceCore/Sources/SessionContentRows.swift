import StructuredQueries

@Table("session_contents")
struct SessionContentRow {
  @Column("session_id") var sessionID: String
  @Column("id") var id: String
  @Column("payload") var payload: String
}

@Table("session_pointers")
struct SessionPointerRow {
  @Column("session_id") var sessionID: String
  @Column("generation") var generation: Int64
  @Column("position") var position: Int64
  @Column("content_id") var contentID: String
}
