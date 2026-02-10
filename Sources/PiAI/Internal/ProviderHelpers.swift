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
  for i in message.content.indices {
    if case var .text(part) = message.content[i] {
      part.text += delta
      message.content[i] = .text(part)
      return
    }
  }

  message.content.append(.text(.init(text: delta)))
}
