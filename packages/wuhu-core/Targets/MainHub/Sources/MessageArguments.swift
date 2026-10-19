public struct SendMessageArguments: Decodable, Sendable {
  public var message: String
  public var conversation: String?
  public var session: String?
  public var replyTarget: String?
  public var attachments: [String]?

  public init(message: String, conversation: String? = nil, session: String? = nil, replyTarget: String? = nil, attachments: [String]? = nil) {
    self.message = message; self.conversation = conversation; self.session = session; self.replyTarget = replyTarget; self.attachments = attachments
  }

  enum CodingKeys: String, CodingKey {
    case message
    case conversation
    case session
    case replyTarget = "reply_target"
    case attachments
  }
}

public struct RequestArguments: Decodable, Sendable {
  public var task: String
  public var message: String
  public var deadlineSeconds: Double?
  public var stallSeconds: Double?

  public init(task: String, message: String, deadlineSeconds: Double? = nil, stallSeconds: Double? = nil) {
    self.task = task; self.message = message; self.deadlineSeconds = deadlineSeconds; self.stallSeconds = stallSeconds
  }

  enum CodingKeys: String, CodingKey {
    case task
    case message
    case deadlineSeconds = "deadline_seconds"
    case stallSeconds = "stall_seconds"
  }
}
