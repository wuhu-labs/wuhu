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
  var waitSeconds: Double?
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
    case waitSeconds = "wait_seconds"
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

struct QueryArguments: Decodable {
  var sql: String
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
