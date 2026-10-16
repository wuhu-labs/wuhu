#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import OrderedCollections
import WuhuAI

/// Replaces every credential the agent knows of with `***`: the request's credential and the session token it was started under.
struct Masker {
  /// Longest first, so a secret containing another is replaced whole.
  let secrets: [String]

  init(credential: AgentRequest.Credential, environment: [String: String]) {
    secrets = (credential.secrets + [environment["WUHU_TOKEN"] ?? ""]).filter { !$0.isEmpty }.sorted { $0.count > $1.count }
  }

  func callAsFunction(_ text: String) -> String {
    secrets.reduce(text) { $0.replacing($1, with: "***") }
  }

  /// Masks the strings where they live, never the encoded message: escaping cannot hide a secret from it and a short secret cannot hit a field name.
  func callAsFunction(_ message: Message) -> Message {
    switch message {
    case var .user(user):
      user.content = user.content.compactMap(mask)
      return .user(user)
    case var .assistant(assistant):
      assistant.content = assistant.content.compactMap(mask)
      return .assistant(assistant)
    case var .toolResult(result):
      result.content = result.content.compactMap(mask)
      return .toolResult(result)
    }
  }

  /// A block whose masked form cannot be represented is dropped.
  private func mask(_ block: ContentBlock) -> ContentBlock? {
    switch block {
    case var .text(content):
      content.text = self(content.text)
      return .text(content)
    case let .reasoning(.unencrypted(text)):
      return .reasoning(.unencrypted(self(text)))
    case var .reasoning(.encrypted(content)):
      content.summary = content.summary.map { self($0) }
      content.opaque = self(content.opaque)
      return .reasoning(.encrypted(content))
    case var .toolCall(call):
      call.name = self(call.name)
      if let arguments = JSONValue.parse(call.arguments.text) {
        let masked = mask(arguments)
        if masked != arguments { call.arguments = ToolArguments(masked) }
      } else if self(call.arguments.text) != call.arguments.text {
        call.arguments = ToolArguments(.object([:]))
      }
      return .toolCall(call)
    case let .hostedTool(content):
      let payload = mask(content.payload)
      guard payload != content.payload else { return block }
      return HostedToolContent(providerID: content.providerID, payload: payload, replayScope: content.replayScope).map(ContentBlock.hostedTool)
    case var .media(content):
      let url = self(content.url.absoluteString)
      guard url != content.url.absoluteString else { return block }
      guard let masked = URL(string: url) else { return nil }
      content.url = masked
      return .media(content)
    }
  }

  private func mask(_ value: JSONValue) -> JSONValue {
    switch value {
    case let .string(text): .string(self(text))
    case let .array(items): .array(items.map(mask))
    case let .object(fields): .object(OrderedDictionary(fields.map { (self($0.key), mask($0.value)) }, uniquingKeysWith: { _, last in last }))
    case .null, .bool, .integer, .number: value
    }
  }
}
