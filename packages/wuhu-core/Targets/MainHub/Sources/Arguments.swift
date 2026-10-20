import enum JSONValue.JSONValue

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

public struct ObserveArguments: Decodable, Sendable {
  public var handler: String?
  public var sql: String
  public var throttleSeconds: Double?

  public init(sql: String, throttleSeconds: Double? = nil, handler: String? = nil) {
    self.sql = sql; self.throttleSeconds = throttleSeconds; self.handler = handler
  }

  enum CodingKeys: String, CodingKey {
    case sql
    case handler
    case throttleSeconds = "throttle_seconds"
  }
}

public struct TimerArguments: Decodable, Sendable {
  public var handler: String?
  public var message: String
  public var inSeconds: Double?
  public var cron: String?

  public init(message: String, inSeconds: Double? = nil, cron: String? = nil, handler: String? = nil) {
    self.message = message; self.inSeconds = inSeconds; self.cron = cron; self.handler = handler
  }

  enum CodingKeys: String, CodingKey {
    case message
    case handler
    case inSeconds = "in_seconds"
    case cron
  }
}

public struct ReportArguments: Decodable, Sendable {
  public var requestID: String
  public var kind: String
  public var content: String

  public init(requestID: String, kind: String, content: String) {
    self.requestID = requestID; self.kind = kind; self.content = content
  }

  enum CodingKeys: String, CodingKey {
    case requestID = "request_id"
    case kind
    case content
  }
}

public struct CreateSessionArguments: Decodable, Sendable {
  public var executor: String? = nil
  public var title: String
  public var kind: String?
  public var topLevel: Bool?
  public var group: String?
  public var provider: String?
  public var model: String?
  public var modelGroup: String? = nil
  public var effort: String?
  public var tags: [String]?
  public var template: String?
  public var expectsReply: Bool?
  public var message: String?
  public var stallSeconds: Double?

  public init(
    title: String, kind: String? = nil, executor: String? = nil, topLevel: Bool? = nil, group: String? = nil,
    provider: String? = nil, model: String? = nil, modelGroup: String? = nil, effort: String? = nil,
    tags: [String]? = nil, template: String? = nil, expectsReply: Bool? = nil, message: String? = nil, stallSeconds: Double? = nil,
  ) {
    self.title = title; self.kind = kind; self.executor = executor; self.topLevel = topLevel; self.group = group
    self.provider = provider; self.model = model; self.modelGroup = modelGroup; self.effort = effort
    self.tags = tags; self.template = template; self.expectsReply = expectsReply; self.message = message; self.stallSeconds = stallSeconds
  }

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

public struct SetTitleArguments: Decodable, Sendable {
  public var title: String

  public init(title: String) { self.title = title }
}
