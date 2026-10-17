import enum JSONValue.JSONValue

struct ReadArguments: Decodable {
  var path: String
  var lines: String?
}

struct WriteArguments: Decodable {
  var path: String
  var content: String
}

struct EditArguments: Decodable {
  struct Edit: Decodable {
    var old: String
    var new: String
  }

  var path: String
  var edits: [Edit]
}

struct GrepArguments: Decodable {
  var pattern: String
  var path: String?
  var matchLimit: Int?
  var hidden: Bool?
  var noIgnore: Bool?
  var step: String?

  enum CodingKeys: String, CodingKey {
    case pattern
    case path
    case matchLimit = "match_limit"
    case hidden
    case noIgnore = "no_ignore"
    case step
  }
}

struct FindArguments: Decodable {
  var glob: String
  var path: String?
  var matchLimit: Int?
  var hidden: Bool?
  var noIgnore: Bool?
  var step: String?

  enum CodingKeys: String, CodingKey {
    case glob
    case path
    case matchLimit = "match_limit"
    case hidden
    case noIgnore = "no_ignore"
    case step
  }
}

struct ExecArguments: Decodable {
  var machine: String
  var cwd: String
  var command: String
  var env: [String: String]?
  var secrets: [String: String]?
  var maxLifetimeSeconds: Double?
  /// The old name of `max_lifetime_seconds`, decoded only to refuse it.
  var timeoutSeconds: JSONValue?
  var maxOutput: Int?

  enum CodingKeys: String, CodingKey {
    case machine
    case cwd
    case command
    case env
    case secrets
    case maxLifetimeSeconds = "max_lifetime_seconds"
    case timeoutSeconds = "timeout_seconds"
    case maxOutput = "max_output"
  }
}

struct ObserveArguments: Decodable {
  var handler: String?
  var sql: String
  var throttleSeconds: Double?

  enum CodingKeys: String, CodingKey {
    case sql
    case handler
    case throttleSeconds = "throttle_seconds"
  }
}

struct TimerArguments: Decodable {
  var handler: String?
  var message: String
  var inSeconds: Double?
  var cron: String?

  enum CodingKeys: String, CodingKey {
    case message
    case handler
    case inSeconds = "in_seconds"
    case cron
  }
}

struct CancelArguments: Decodable {
  var subscriptionID: String

  enum CodingKeys: String, CodingKey {
    case subscriptionID = "subscription_id"
  }
}

struct QueryArguments: Decodable {
  var sql: String
}

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

struct ReportArguments: Decodable {
  var requestID: String
  var kind: String
  var content: String

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case kind
    case content
  }
}

struct CreateSessionArguments: Decodable {
  var executor: String? = nil
  var title: String
  var kind: String?
  var topLevel: Bool?
  var group: String?
  var provider: String?
  var model: String?
  var modelGroup: String? = nil
  var effort: String?
  var tags: [String]?
  var template: String?
  var expectsReply: Bool?
  var message: String?
  var stallSeconds: Double?

  enum CodingKeys: String, CodingKey {
    case title
    case kind
    case executor
    case topLevel = "top_level"
    case group
    case provider
    case model
    case modelGroup
    case effort
    case tags
    case template
    case expectsReply = "expects_reply"
    case message
    case stallSeconds = "stall_seconds"
  }
}

struct SetTitleArguments: Decodable {
  var title: String
}

struct GenerateImageArguments: Decodable {
  var prompt: String
  var destination: String
  var provider: String?
  var model: String?
  var quality: String?
  var size: String?
}
