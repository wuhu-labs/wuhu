import JSONValue
import OrderedCollections

public enum ClaudeCode {
  public static let version: String = "2.1.284"
}

public enum ClaudeCodeBlock: Hashable, Sendable {
  case text(String)
  case image(mediaType: String, base64: String)

  var json: JSONValue {
    switch self {
    case let .text(text):
      ["type": "text", "text": .string(text)]
    case let .image(mediaType, base64):
      ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType), "data": .string(base64)]]
    }
  }
}

// One stream-json input line. Claude Code keeps `uuid` as the uuid of the user
// entry it logs, which is how the loop recognises this message in the mirror.
public func claudeCodeUserMessage(uuid: String, content: [ClaudeCodeBlock]) -> [UInt8] {
  let line: JSONValue = [
    "type": "user",
    "uuid": .string(uuid),
    "session_id": "",
    "parent_tool_use_id": .null,
    "message": ["role": "user", "content": .array(content.map(\.json))],
  ]
  return Array((line.jsonString() + "\n").utf8)
}

// Claude Code calls PostToolUseFailure instead of PostToolUse after a tool
// call that failed; a failed call hands over exactly as a successful one.
public enum ClaudeCodeHook: Hashable, Sendable {
  case afterTool(toolUseID: String, failed: Bool)
  case endOfTurn(reentered: Bool)

  public init?(body: JSONValue) {
    guard let fields = body.object else { return nil }
    switch fields["hook_event_name"]?.stringValue {
    case let event? where event == "PostToolUse" || event == "PostToolUseFailure":
      guard let id = fields["tool_use_id"]?.stringValue else { return nil }
      self = .afterTool(toolUseID: id, failed: event == "PostToolUseFailure")
    case "Stop":
      guard let reentered = fields["stop_hook_active"]?.boolValue else { return nil }
      self = .endOfTurn(reentered: reentered)
    default:
      return nil
    }
  }

  // Both hooks hand over as additional context. Blocking a stop would show
  // the model the text twice, once labelled an error; context alone still
  // keeps the turn going, and reaches it once.
  public func reply(handingOver text: String?) -> JSONValue {
    guard let text else { return [:] }
    return ["hookSpecificOutput": ["hookEventName": .string(eventName), "additionalContext": .string(text)]]
  }

  var eventName: String {
    switch self {
    case .afterTool(_, failed: false): "PostToolUse"
    case .afterTool(_, failed: true): "PostToolUseFailure"
    case .endOfTurn: "Stop"
    }
  }

  public var record: ClaudeCodeHandoverRecord {
    switch self {
    case let .afterTool(id, _): .additionalContext(event: eventName, toolUseID: id)
    case .endOfTurn: .additionalContext(event: eventName, toolUseID: nil)
    }
  }
}

// The log entry that proves a handover reached Claude Code's session log.
// The end-of-turn record carries a tool use id Claude Code mints for the
// hook run itself, so it cannot be known in advance; with one handover
// outstanding there is nothing to tell apart.
public enum ClaudeCodeHandoverRecord: Hashable, Sendable {
  case userEntry(uuid: String)
  case additionalContext(event: String, toolUseID: String?)

  public func isRecorded(by entry: OrderedDictionary<String, JSONValue>) -> Bool {
    switch self {
    case let .userEntry(uuid):
      return entry["type"] == "user" && entry["uuid"]?.stringValue == uuid
    case let .additionalContext(event, toolUseID):
      guard entry["type"] == "attachment", let attachment = entry["attachment"]?.object,
            attachment["type"] == "hook_additional_context", attachment["hookEvent"]?.stringValue == event
      else { return false }
      return toolUseID.map { attachment["toolUseID"]?.stringValue == $0 } ?? true
    }
  }
}
