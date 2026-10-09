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
  var entryLimit: Int?
  var step: String?

  enum CodingKeys: String, CodingKey {
    case pattern
    case path
    case matchLimit = "match_limit"
    case entryLimit = "entry_limit"
    case step
  }
}

struct FindArguments: Decodable {
  var glob: String
  var path: String?
  var matchLimit: Int?
  var entryLimit: Int?
  var step: String?

  enum CodingKeys: String, CodingKey {
    case glob
    case path
    case matchLimit = "match_limit"
    case entryLimit = "entry_limit"
    case step
  }
}

struct ExecArguments: Decodable {
  var machine: String
  var cwd: String
  var command: String
  var env: [String: String]?
  var secrets: [String: String]?
  var timeoutSeconds: Double?
  var maxOutput: Int?

  enum CodingKeys: String, CodingKey {
    case machine
    case cwd
    case command
    case env
    case secrets
    case timeoutSeconds = "timeout_seconds"
    case maxOutput = "max_output"
  }
}

struct ObserveArguments: Decodable {
  var sql: String
  var throttleSeconds: Double?

  enum CodingKeys: String, CodingKey {
    case sql
    case throttleSeconds = "throttle_seconds"
  }
}

struct TimerArguments: Decodable {
  var message: String
  var inSeconds: Double?
  var cron: String?

  enum CodingKeys: String, CodingKey {
    case message
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

struct SendMessageArguments: Decodable {
  var message: String
  var conversation: String?
  var session: String?
  var replyTarget: String?
  var attachments: [String]?

  enum CodingKeys: String, CodingKey {
    case message
    case conversation
    case session
    case replyTarget = "reply_target"
    case attachments
  }
}

struct RequestArguments: Decodable {
  var task: String
  var message: String
  var deadlineSeconds: Double?

  enum CodingKeys: String, CodingKey {
    case task
    case message
    case deadlineSeconds = "deadline_seconds"
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
  var title: String
  var kind: String?
  var topLevel: Bool?
  var group: String?
  var provider: String?
  var model: String?
  var effort: String?
  var tags: [String]?
  var template: String?
  var expectsReply: Bool?
  var message: String?

  enum CodingKeys: String, CodingKey {
    case title
    case kind
    case topLevel = "top_level"
    case group
    case provider
    case model
    case effort
    case tags
    case template
    case expectsReply = "expects_reply"
    case message
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
