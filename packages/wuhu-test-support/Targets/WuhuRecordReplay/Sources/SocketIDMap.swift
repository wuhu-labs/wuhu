import FetchWebSocket
import JSONValue

struct SocketIDMap: Sendable {
  private var forward: [String: String] = [:]
  private var reverse: [String: String] = [:]

  mutating func matches(_ expected: WebSocketMessage, _ actual: WebSocketMessage) -> Bool {
    switch (expected, actual) {
    case (.binary(let lhs), .binary(let rhs)): return lhs == rhs
    case (.text(let lhs), .text(let rhs)):
      guard let left = JSONValue.parse(lhs), let right = JSONValue.parse(rhs) else { return lhs == rhs }
      var candidate = self
      guard candidate.compare(left, right, key: "") else { return false }
      self = candidate
      return true
    default: return false
    }
  }

  mutating func received(_ message: WebSocketMessage) -> WebSocketMessage {
    guard case .text(let text) = message, let value = JSONValue.parse(text) else { return message }
    return .text(project(value, key: "").jsonString())
  }

  private func namespace(_ value: String, key: String) -> String? {
    if key == "arguments" { return nil }
    if key == "previous_response_id" || key == "response_id" || key == "response.id" || (key == "id" && value.hasPrefix("resp_")) { return "response:" }
    if key == "call_id" { return "call:" }
    if key == "id" && value.hasPrefix("call_") { return "call:" }
    if key == "item_reference.id" || key == "item_id" || (key == "id" && value.hasPrefix("fc_")) { return "item:" }
    return nil
  }

  private mutating func bind(_ lhs: String, _ rhs: String, namespace: String) -> Bool {
    let l = namespace + lhs, r = namespace + rhs
    if let mapped = forward[l] { return mapped == rhs }
    guard reverse[r] == nil else { return false }
    forward[l] = rhs
    reverse[r] = lhs
    return true
  }

  private mutating func compare(_ lhs: JSONValue, _ rhs: JSONValue, key: String, reference: Bool = false) -> Bool {
    switch (lhs, rhs) {
    case (.string(let l), .string(let r)):
      if let namespace = namespace(l, key: key) {
        if reference, forward[namespace + l] == nil, l != r { return false }
        return bind(l, r, namespace: namespace)
      }
      return key == "arguments" ? l == r : compareUUIDs(l, r)
    case (.array(let l), .array(let r)):
      guard l.count == r.count else { return false }
      for (a, b) in zip(l, r) where !compare(a, b, key: key, reference: reference) { return false }
      return true
    case (.object(let l), .object(let r)):
      guard Set(l.keys) == Set(r.keys) else { return false }
      for name in l.keys.sorted() {
        let isReference = ["previous_response_id", "response_id", "item_id"].contains(name)
          || (name == "call_id" && l["type"]?.stringValue != "function_call")
          || (name == "id" && l["type"]?.stringValue == "item_reference")
        if !compare(l[name]!, r[name]!, key: name == "id" && l["type"]?.stringValue == "item_reference" ? "item_reference.id" : (key == "response" && name == "id" ? "response.id" : name), reference: isReference) { return false }
      }
      return true
    default: return lhs == rhs
    }
  }

  private mutating func compareUUIDs(_ lhs: String, _ rhs: String) -> Bool {
    let pattern = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/
    let left = lhs.matches(of: pattern), right = rhs.matches(of: pattern)
    guard left.count == right.count else { return false }
    for (l, r) in zip(left, right) {
      guard bind(String(l.output).lowercased(), String(r.output).lowercased(), namespace: "uuid:") else { return false }
    }
    return lhs.replacing(pattern, with: "<uuid>") == rhs.replacing(pattern, with: "<uuid>")
  }

  private mutating func project(_ value: JSONValue, key: String) -> JSONValue {
    switch value {
    case .string(let text):
      guard let namespace = namespace(text, key: key) else { return value }
      if let name = forward[namespace + text] { return .string(name) }
      var projected = text
      var suffix = 0
      while reverse[namespace + projected] != nil {
        suffix += 1
        projected = text + "__replay_\(suffix)"
      }
      precondition(bind(text, projected, namespace: namespace))
      return .string(projected)
    case .array(let items): return .array(items.map { project($0, key: key) })
    case .object(var fields):
      for name in fields.keys.sorted() { fields[name] = project(fields[name]!, key: key == "response" && name == "id" ? "response.id" : name) }
      return .object(fields)
    default: return value
    }
  }
}
