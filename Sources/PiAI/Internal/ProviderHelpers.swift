import Foundation

func resolveAPIKey(_ explicit: String?, env: String, provider: Provider) throws -> String {
  if let explicit, !explicit.isEmpty { return explicit }
  if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty { return value }
  throw PiAIError.missingAPIKey(provider: provider)
}

func envBool(_ key: String) -> Bool? {
  guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else { return nil }
  switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
  case "1", "true", "t", "yes", "y", "on":
    return true
  case "0", "false", "f", "no", "n", "off":
    return false
  default:
    return nil
  }
}

func parseJSON(_ text: String) throws -> [String: Any]? {
  let data = Data(text.utf8)
  let obj = try JSONSerialization.jsonObject(with: data)
  return obj as? [String: Any]
}

func applyTextDelta(_ delta: String, to message: inout AssistantMessage) {
  if let last = message.content.last, case var .text(part) = last {
    part.text += delta
    message.content[message.content.count - 1] = .text(part)
  } else {
    message.content.append(.text(.init(text: delta)))
  }
}
