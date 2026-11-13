import StructuredQueries

@Table("session_queue")
public struct SessionQueueRow {
  @Column("session_id") public var sessionID: String
  public var id: Int64
  @Column("input_id") public var inputID: String
  public var payload: String
  @Column("enqueued_at") public var enqueuedAt: String
  public var topic: String?
  @Column("due_at") public var dueAt: String?

  public init(sessionID: String, id: Int64, inputID: String, payload: String, enqueuedAt: String, topic: String?, dueAt: String?) {
    self.sessionID = sessionID
    self.id = id
    self.inputID = inputID
    self.payload = payload
    self.enqueuedAt = enqueuedAt
    self.topic = topic
    self.dueAt = dueAt
  }
}
