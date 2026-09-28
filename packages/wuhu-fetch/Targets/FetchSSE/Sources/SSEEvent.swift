public struct SSEEvent: Sendable, Equatable {
  public var event: String
  public var data: String
  public var id: String?
  public var retry: Int?

  public init(
    event: String = "message",
    data: String,
    id: String? = nil,
    retry: Int? = nil,
  ) {
    self.event = event
    self.data = data
    self.id = id
    self.retry = retry
  }
}
