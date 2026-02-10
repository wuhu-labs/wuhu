import Foundation

func resolveAPIKey(_ explicit: String?, env: String, provider: Provider) throws -> String {
  if let explicit, !explicit.isEmpty { return explicit }
  if let value = ProcessInfo.processInfo.environment[env], !value.isEmpty { return value }
  throw PiAIError.missingAPIKey(provider: provider)
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
