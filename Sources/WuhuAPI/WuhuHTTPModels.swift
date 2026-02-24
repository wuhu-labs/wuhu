import Foundation
import PiAI

public struct WuhuCreateSessionRequest: Sendable, Hashable, Codable {
  public var type: WuhuSessionType?
  public var provider: WuhuProvider
  public var model: String?
  public var reasoningEffort: ReasoningEffort?
  public var systemPrompt: String?
  /// Environment identifier (UUID or unique name).
  public var environment: String?
  /// Direct environment path (bypass environment definitions). Intended for channel-agent workflows.
  public var environmentPath: String?
  public var runner: String?
  public var parentSessionID: String?

  public init(
    type: WuhuSessionType? = nil,
    provider: WuhuProvider,
    model: String? = nil,
    reasoningEffort: ReasoningEffort? = nil,
    systemPrompt: String? = nil,
    environment: String? = nil,
    environmentPath: String? = nil,
    runner: String? = nil,
    parentSessionID: String? = nil,
  ) {
    self.type = type
    self.provider = provider
    self.model = model
    self.reasoningEffort = reasoningEffort
    self.systemPrompt = systemPrompt
    self.environment = environment
    self.environmentPath = environmentPath
    self.runner = runner
    self.parentSessionID = parentSessionID
  }
}

public struct WuhuSetSessionModelRequest: Sendable, Hashable, Codable {
  public var provider: WuhuProvider
  /// If nil/empty, the server uses its default model for this provider.
  public var model: String?
  /// If nil, the server clears any session-level override (use default behavior for the model).
  public var reasoningEffort: ReasoningEffort?

  public init(provider: WuhuProvider, model: String? = nil, reasoningEffort: ReasoningEffort? = nil) {
    self.provider = provider
    self.model = model
    self.reasoningEffort = reasoningEffort
  }
}

public struct WuhuSetSessionModelResponse: Sendable, Hashable, Codable {
  public var session: WuhuSession
  /// The resolved selection the server will use (includes provider defaults).
  public var selection: WuhuSessionSettings
  /// True if the selection became effective immediately; false if it will be applied once the session is idle.
  public var applied: Bool

  public init(session: WuhuSession, selection: WuhuSessionSettings, applied: Bool) {
    self.session = session
    self.selection = selection
    self.applied = applied
  }
}

public struct WuhuGetSessionResponse: Sendable, Hashable, Codable {
  public var session: WuhuSession
  public var transcript: [WuhuSessionEntry]
  /// Best-effort, in-process execution info from the server that served this request.
  /// May be nil when talking to older servers.
  public var inProcessExecution: WuhuInProcessExecutionInfo?

  public init(session: WuhuSession, transcript: [WuhuSessionEntry], inProcessExecution: WuhuInProcessExecutionInfo? = nil) {
    self.session = session
    self.transcript = transcript
    self.inProcessExecution = inProcessExecution
  }
}

public struct WuhuInProcessExecutionInfo: Sendable, Hashable, Codable {
  public var activePromptCount: Int

  public init(activePromptCount: Int) {
    self.activePromptCount = activePromptCount
  }
}

public struct WuhuRunnerInfo: Sendable, Hashable, Codable, Identifiable {
  public var name: String
  public var connected: Bool

  public var id: String {
    name
  }

  public init(name: String, connected: Bool) {
    self.name = name
    self.connected = connected
  }
}

public struct WuhuToolResult: Sendable, Hashable, Codable {
  public var content: [WuhuContentBlock]
  public var details: JSONValue

  public init(content: [WuhuContentBlock], details: JSONValue) {
    self.content = content
    self.details = details
  }
}

public enum WuhuSessionStreamEvent: Sendable, Hashable, Codable {
  case entryAppended(WuhuSessionEntry)
  case assistantTextDelta(String)
  case idle
  case done

  enum CodingKeys: String, CodingKey {
    case type
    case entry
    case delta
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "entry_appended":
      self = try .entryAppended(c.decode(WuhuSessionEntry.self, forKey: .entry))
    case "assistant_text_delta":
      self = try .assistantTextDelta(c.decode(String.self, forKey: .delta))
    case "idle":
      self = .idle
    case "done":
      self = .done
    default:
      throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown session stream event type: \\(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case let .entryAppended(entry):
      try c.encode("entry_appended", forKey: .type)
      try c.encode(entry, forKey: .entry)
    case let .assistantTextDelta(delta):
      try c.encode("assistant_text_delta", forKey: .type)
      try c.encode(delta, forKey: .delta)
    case .idle:
      try c.encode("idle", forKey: .type)
    case .done:
      try c.encode("done", forKey: .type)
    }
  }
}

public struct WuhuRenameSessionRequest: Sendable, Hashable, Codable {
  public var title: String

  public init(title: String) {
    self.title = title
  }
}

public struct WuhuRenameSessionResponse: Sendable, Hashable, Codable {
  public var session: WuhuSession

  public init(session: WuhuSession) {
    self.session = session
  }
}

public struct WuhuStopSessionRequest: Sendable, Hashable, Codable {
  public var user: String?

  public init(user: String? = nil) {
    self.user = user
  }
}

public struct WuhuStopSessionResponse: Sendable, Hashable, Codable {
  public var repairedEntries: [WuhuSessionEntry]
  public var stopEntry: WuhuSessionEntry?

  public init(repairedEntries: [WuhuSessionEntry], stopEntry: WuhuSessionEntry?) {
    self.repairedEntries = repairedEntries
    self.stopEntry = stopEntry
  }
}
