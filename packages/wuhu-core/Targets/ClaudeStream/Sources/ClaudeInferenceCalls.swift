import JSONValue
import OrderedCollections

public struct ClaudeInferenceCalls: Sendable {
  public struct Call: Sendable, Equatable {
    public enum Outcome: String, Sendable {
      case ok
      case cancelled
    }

    public struct Usage: Sendable, Equatable {
      public let inputTokens: Int?
      public let cacheReadInputTokens: Int?
      public let cacheCreationInputTokens: Int?
      public let outputTokens: Int?
    }

    public let id: String
    public let timestamp: String
    public let model: String?
    public let usage: Usage
    public let outcome: Outcome
  }

  private struct UsageUpdate: Sendable {
    var input: Int?
    var cacheRead: Int?
    var cacheWrite: Int?
    var output: Int?

    mutating func merge(_ usage: OrderedDictionary<String, JSONValue>) {
      input = usage["input_tokens"]?.intValue ?? input
      cacheRead = usage["cache_read_input_tokens"]?.intValue ?? cacheRead
      cacheWrite = usage["cache_creation_input_tokens"]?.intValue ?? cacheWrite
      output = usage["output_tokens"]?.intValue ?? output
    }

    func applying(to usage: ClaudeStreamFrame.Usage?, includeOutput: Bool) -> Call.Usage {
      .init(
        inputTokens: input ?? usage?.inputTokens,
        cacheReadInputTokens: cacheRead ?? usage?.cacheReadInputTokens,
        cacheCreationInputTokens: cacheWrite ?? usage?.cacheCreationInputTokens,
        outputTokens: includeOutput ? output ?? usage?.outputTokens : nil,
      )
    }
  }

  private struct Stream: Sendable {
    let receivedAt: String
    var usage = UsageUpdate()
    var assistant: ClaudeStreamFrame.Assistant?
    var stopped = false
    var hasOutputDelta = false
  }

  private var pending: ClaudeStreamFrame.Assistant?
  private var streams: [String: Stream] = [:]
  private var active: [String?: String] = [:]
  private var completed: Set<String> = []

  public init() {}

  public mutating func record(_ frame: ClaudeStreamFrame, at timestamp: String) -> [Call] {
    switch frame {
    case let .assistant(assistant):
      guard !completed.contains(assistant.id) else { return [] }
      if var stream = streams[assistant.id] {
        stream.assistant = .init(
          id: assistant.id, timestamp: stream.assistant?.timestamp ?? assistant.timestamp,
          model: assistant.model, usage: assistant.usage,
        )
        streams[assistant.id] = stream
        return stream.stopped ? finish(assistant.id) : []
      }
      let finished = pending.map { $0.id != assistant.id } == true ? drainPending() : []
      pending = .init(
        id: assistant.id, timestamp: pending?.timestamp ?? assistant.timestamp,
        model: assistant.model, usage: assistant.usage,
      )
      return finished
    case .result:
      return drain()
    case let .other(value):
      guard let object = value.object else { return [] }
      switch object["type"]?.stringValue {
      case "stream_event":
        return recordStream(object, at: timestamp)
      case "user", "tool_result":
        return drainPending()
      default:
        return []
      }
    default:
      return []
    }
  }

  public mutating func drain() -> [Call] {
    let finished = streams.keys.sorted().flatMap { finish($0, allowingMissingAssistant: true) }
    active.removeAll()
    return finished + drainPending()
  }

  private mutating func recordStream(_ frame: OrderedDictionary<String, JSONValue>, at timestamp: String) -> [Call] {
    guard let event = frame["event"]?.object else { return [] }
    let parent = frame["parent_tool_use_id"]?.stringValue
    switch event["type"]?.stringValue {
    case "message_start":
      guard let message = event["message"]?.object, let id = message["id"]?.stringValue else { return [] }
      active[parent] = id
      guard !completed.contains(id), streams[id] == nil else { return [] }
      var stream = Stream(receivedAt: timestamp)
      if let usage = message["usage"]?.object { stream.usage.merge(usage) }
      streams[id] = stream
      return []
    case "message_delta":
      guard let id = active[parent], var stream = streams[id],
            let usage = event["usage"]?.object
      else { return [] }
      stream.usage.merge(usage)
      stream.hasOutputDelta = stream.hasOutputDelta || usage["output_tokens"]?.intValue != nil
      streams[id] = stream
      return []
    case "message_stop":
      guard let id = active.removeValue(forKey: parent), var stream = streams[id] else { return [] }
      stream.stopped = true
      streams[id] = stream
      return finish(id)
    default:
      return []
    }
  }

  private mutating func finish(_ id: String, allowingMissingAssistant: Bool = false) -> [Call] {
    guard let stream = streams[id], allowingMissingAssistant || stream.assistant != nil else { return [] }
    streams.removeValue(forKey: id)
    completed.insert(id)
    return [.init(
      id: id, timestamp: stream.assistant?.timestamp ?? stream.receivedAt, model: stream.assistant?.model,
      usage: stream.usage.applying(to: stream.assistant?.usage, includeOutput: stream.hasOutputDelta),
      outcome: stream.stopped ? .ok : .cancelled,
    )]
  }

  private mutating func drainPending() -> [Call] {
    guard let pending else { return [] }
    self.pending = nil
    completed.insert(pending.id)
    return [.init(
      id: pending.id, timestamp: pending.timestamp, model: pending.model,
      usage: UsageUpdate().applying(to: pending.usage, includeOutput: true), outcome: .ok,
    )]
  }
}
