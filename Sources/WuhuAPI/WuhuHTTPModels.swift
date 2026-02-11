import Foundation
import PiAI

public struct WuhuCreateSessionRequest: Sendable, Hashable, Codable {
  public var provider: WuhuProvider
  public var model: String?
  public var systemPrompt: String?
  public var environment: String
  public var runner: String?
  public var parentSessionID: String?

  public init(
    provider: WuhuProvider,
    model: String? = nil,
    systemPrompt: String? = nil,
    environment: String,
    runner: String? = nil,
    parentSessionID: String? = nil,
  ) {
    self.provider = provider
    self.model = model
    self.systemPrompt = systemPrompt
    self.environment = environment
    self.runner = runner
    self.parentSessionID = parentSessionID
  }
}

public struct WuhuPromptRequest: Sendable, Hashable, Codable {
  public var input: String
  public var user: String?
  public var detach: Bool?

  public init(input: String, user: String? = nil, detach: Bool? = nil) {
    self.input = input
    self.user = user
    self.detach = detach
  }
}

public struct WuhuPromptDetachedResponse: Sendable, Hashable, Codable {
  public var userEntry: WuhuSessionEntry

  public init(userEntry: WuhuSessionEntry) {
    self.userEntry = userEntry
  }
}

public struct WuhuGetSessionResponse: Sendable, Hashable, Codable {
  public var session: WuhuSession
  public var transcript: [WuhuSessionEntry]

  public init(session: WuhuSession, transcript: [WuhuSessionEntry]) {
    self.session = session
    self.transcript = transcript
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

public struct WuhuEnvironmentInfo: Sendable, Hashable, Codable, Identifiable {
  public var name: String
  public var type: String

  public var id: String {
    name
  }

  public init(name: String, type: String) {
    self.name = name
    self.type = type
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
