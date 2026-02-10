import Foundation

func resolveAPIKey(_ explicit: String?, env: String, provider: Provider) throws -> String {
  if let explicit, !explicit.isEmpty { return explicit }
  if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty { return value }
  throw PiAIError.missingAPIKey(provider: provider)
}

func envFlag(_ key: String, default defaultValue: Bool = false) -> Bool {
  guard let raw = ProcessInfo.processInfo.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !raw.isEmpty
  else { return defaultValue }

  switch raw.lowercased() {
  case "1", "true", "yes", "y", "on":
    return true
  case "0", "false", "no", "n", "off":
    return false
  default:
    return defaultValue
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
