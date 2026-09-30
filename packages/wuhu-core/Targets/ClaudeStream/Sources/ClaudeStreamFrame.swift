import JSONValue
import OrderedCollections

public enum ClaudeStreamFrame: Sendable, Equatable {
  case initialization(Initialization)
  case transcriptMirror(entries: [OrderedDictionary<String, JSONValue>])
  case assistant(Assistant)
  case result(TurnResult)
  case compactBoundary(CompactBoundary)
  case rateLimit(RateLimit)
  // An init, assistant, mirror or result frame the loop cannot read: the session cannot
  // go on without it, so it must never pass as `.other`.
  case malformed(JSONValue)
  case other(JSONValue)
  case undecodable([UInt8])

  public struct Initialization: Sendable, Equatable {
    let sessionID: String
    let version: String
    let model: String
  }

  public struct Assistant: Sendable, Equatable {
    public let id: String
    public let timestamp: String
    public let model: String
    public let usage: Usage
  }

  public struct TurnResult: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
      case success
      case errorDuringExecution
      case errorMaxTurns
      case errorMaxBudget
      case errorMaxStructuredOutputRetries
      case unknown(String)
    }

    public let outcome: Outcome
    public let isError: Bool
    public let usage: Usage?
    // What the turn answered; for a failed turn, the error Claude Code met.
    public let text: String?
  }

  public struct Usage: Sendable, Equatable {
    public let inputTokens: Int
    public let cacheReadInputTokens: Int
    public let cacheCreationInputTokens: Int
    public let outputTokens: Int

    public var contextTokens: Int { inputTokens + cacheReadInputTokens }
  }

  public struct CompactBoundary: Sendable, Equatable {
    enum Trigger: String, Sendable {
      case manual
      case auto
    }

    let trigger: Trigger
    let preTokens: Int
  }

  // utilization is a fraction of the window; windows carries every window the
  // response headers named, type the one that decided status.
  public struct RateLimit: Sendable, Equatable {
    enum Status: String, Sendable {
      case allowed
      case allowedWarning = "allowed_warning"
      case rejected
    }

    public struct Window: Sendable, Equatable {
      public let name: String
      public let utilization: Double
      public let resetsAt: Double
    }

    let status: Status
    public let type: String?
    public let utilization: Double?
    public let resetsAt: Double?
    public let windows: [Window]
  }
}

extension ClaudeStreamFrame {
  init(line: ArraySlice<UInt8>) {
    guard let value = JSONValue.parse(utf8: line) else {
      self = .undecodable(Array(line))
      return
    }
    guard let frame = value.object else {
      self = .other(value)
      return
    }
    switch (frame["type"]?.stringValue, frame["subtype"]?.stringValue) {
    case ("system", "init"):
      self = Self.initialization(frame).map(Self.initialization) ?? .malformed(value)
    case ("transcript_mirror", _):
      self = frame["entries"]?.array?.objects.map { .transcriptMirror(entries: $0) } ?? .malformed(value)
    case ("assistant", _):
      self = Self.assistant(frame).map(Self.assistant) ?? .malformed(value)
    case ("result", _):
      self = Self.result(frame).map(Self.result) ?? .malformed(value)
    case ("system", "compact_boundary"):
      self = Self.compactBoundary(frame).map(Self.compactBoundary) ?? .other(value)
    case ("rate_limit_event", _):
      self = Self.rateLimit(frame).map(Self.rateLimit) ?? .other(value)
    default:
      self = .other(value)
    }
  }

  private static func initialization(_ frame: OrderedDictionary<String, JSONValue>) -> Initialization? {
    guard let sessionID = frame["session_id"]?.stringValue,
          let version = frame["claude_code_version"]?.stringValue,
          let model = frame["model"]?.stringValue
    else { return nil }
    return Initialization(sessionID: sessionID, version: version, model: model)
  }

  private static func assistant(_ frame: OrderedDictionary<String, JSONValue>) -> Assistant? {
    guard let message = frame["message"]?.object,
          let id = message["id"]?.stringValue,
          let timestamp = frame["timestamp"]?.stringValue,
          let model = message["model"]?.stringValue,
          let usage = message["usage"]?.object.flatMap(Usage.init)
    else { return nil }
    return Assistant(id: id, timestamp: timestamp, model: model, usage: usage)
  }

  private static func result(_ frame: OrderedDictionary<String, JSONValue>) -> TurnResult? {
    guard let subtype = frame["subtype"]?.stringValue, let isError = frame["is_error"]?.boolValue else { return nil }
    return TurnResult(
      outcome: TurnResult.Outcome(subtype),
      isError: isError,
      usage: frame["usage"]?.object.flatMap(Usage.init),
      text: frame["result"]?.stringValue,
    )
  }

  private static func compactBoundary(_ frame: OrderedDictionary<String, JSONValue>) -> CompactBoundary? {
    guard let metadata = frame["compact_metadata"]?.object,
          let trigger = metadata["trigger"]?.stringValue.flatMap(CompactBoundary.Trigger.init),
          let preTokens = metadata["pre_tokens"]?.intValue
    else { return nil }
    return CompactBoundary(trigger: trigger, preTokens: preTokens)
  }

  private static func rateLimit(_ frame: OrderedDictionary<String, JSONValue>) -> RateLimit? {
    guard let info = frame["rate_limit_info"]?.object,
          let status = info["status"]?.stringValue.flatMap(RateLimit.Status.init),
          let type = info.optional("rateLimitType", \.stringValue),
          let utilization = info.optional("utilization", \.doubleValue),
          let resetsAt = info.optional("resetsAt", \.doubleValue)
    else { return nil }
    var windows: [RateLimit.Window] = []
    if let unified = info["unifiedWindows"] {
      guard let named = unified.object else { return nil }
      for (name, value) in named {
        guard let window = value.object,
              let utilization = window["utilization"]?.doubleValue,
              let resetsAt = window["resetsAt"]?.doubleValue
        else { return nil }
        windows.append(RateLimit.Window(name: name, utilization: utilization, resetsAt: resetsAt))
      }
    }
    return RateLimit(status: status, type: type, utilization: utilization, resetsAt: resetsAt, windows: windows)
  }
}

extension ClaudeStreamFrame.TurnResult.Outcome {
  init(_ subtype: String) {
    self = switch subtype {
    case "success": .success
    case "error_during_execution": .errorDuringExecution
    case "error_max_turns": .errorMaxTurns
    case "error_max_budget_usd": .errorMaxBudget
    case "error_max_structured_output_retries": .errorMaxStructuredOutputRetries
    default: .unknown(subtype)
    }
  }
}

extension ClaudeStreamFrame.Usage {
  init?(_ usage: OrderedDictionary<String, JSONValue>) {
    guard let inputTokens = usage["input_tokens"]?.intValue,
          let cacheRead = usage["cache_read_input_tokens"]?.intValue,
          let cacheCreation = usage["cache_creation_input_tokens"]?.intValue,
          let outputTokens = usage["output_tokens"]?.intValue
    else { return nil }
    self.init(
      inputTokens: inputTokens,
      cacheReadInputTokens: cacheRead,
      cacheCreationInputTokens: cacheCreation,
      outputTokens: outputTokens,
    )
  }
}

extension [JSONValue] {
  fileprivate var objects: [OrderedDictionary<String, JSONValue>]? {
    var objects: [OrderedDictionary<String, JSONValue>] = []
    objects.reserveCapacity(count)
    for element in self {
      guard let object = element.object else { return nil }
      objects.append(object)
    }
    return objects
  }
}

extension OrderedDictionary<String, JSONValue> {
  // Absent is a value (nil); present with the wrong type is a changed shape (nil outer).
  fileprivate func optional<T>(_ key: String, _ read: (JSONValue) -> T?) -> T?? {
    guard let value = self[key], value != .null else { return .some(nil) }
    return read(value).map { .some($0) }
  }
}
