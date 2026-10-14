import Clocks
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import JSONValue
import QuickJSKit
import SessionDomain
import SpaceCore
import WuhuAI

struct CompletionError: Error {
  let code: String
  let message: String

  var payload: JSONValue { .object(["code": .string(code), "message": .string(message)]) }
}

extension ScriptAI {
  func installCompletion(in engine: JSEngine) {
    engine.define("__wuhu_complete", promising: { [session, tools] arguments in
      do {
        let request = try CompletionRequest(input: arguments.first, options: arguments[safe: 1])
        return .object(["ok": .string(try await tools.complete(session, request))])
      } catch is CancellationError {
        throw CancellationError()
      } catch let error as CompletionError {
        return .object(["error": error.payload])
      } catch {
        return .object(["error": CompletionError(code: "inferenceFailed", message: "Completion failed.").payload])
      }
    })
  }
}

struct CompletionRequest {
  let provider: String
  let model: String
  let context: Context
  let schema: JSONValue?

  init(input: JSONValue?, options: JSONValue?) throws {
    guard let options = options?.object else {
      throw CompletionError(code: "missingModel", message: "complete needs { model: \"provider/model\" }.")
    }
    guard options.keys.allSatisfy({ ["model", "schema"].contains($0) }) else {
      throw CompletionError(code: "invalidArgument", message: "complete accepts only model and schema options; tools are not supported.")
    }
    guard let name = options["model"]?.stringValue, !name.isEmpty else {
      throw CompletionError(code: "missingModel", message: "complete requires a model from /models.json.")
    }
    if let separator = name.firstIndex(of: "/") {
      guard separator != name.startIndex, name.index(after: separator) != name.endIndex else {
        throw CompletionError(code: "unknownModel", message: "Model must be a provider/model name from /models.json.")
      }
      provider = String(name[..<separator])
      model = String(name[name.index(after: separator)...])
    } else {
      provider = name
      model = ""
    }
    if let value = options["schema"] {
      guard value.object != nil else {
        throw CompletionError(code: "invalidArgument", message: "schema must be a JSON schema object.")
      }
      schema = value
    } else { schema = nil }
    switch input {
    case let .string(prompt):
      guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CompletionError(code: "invalidArgument", message: "complete needs a nonempty prompt.")
      }
      context = Context(messages: [.user(.init(content: [.text(prompt)]))])
    case let .array(values):
      var system: [String] = []
      var messages: [Message] = []
      for value in values {
        guard let item = value.object, item.keys.allSatisfy({ ["role", "content"].contains($0) }),
              let role = item["role"]?.stringValue, let text = item["content"]?.stringValue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CompletionError(code: "invalidArgument", message: "Messages need role and nonempty string content.") }
        switch role {
        case "system":
          guard messages.isEmpty else { throw CompletionError(code: "invalidArgument", message: "System messages must precede conversation messages.") }
          system.append(text)
        case "user": messages.append(.user(.init(content: [.text(text)])))
        case "assistant": messages.append(.assistant(.init(content: [.text(text)])))
        default: throw CompletionError(code: "invalidArgument", message: "Only system, user and assistant messages are supported; no tools.")
        }
      }
      guard !messages.isEmpty else { throw CompletionError(code: "invalidArgument", message: "complete needs at least one conversation message.") }
      context = Context(systemPrompt: system.isEmpty ? nil : system.joined(separator: "\n\n"), messages: messages)
    default: throw CompletionError(code: "invalidArgument", message: "complete needs a prompt string or an array of messages.")
    }
  }
}

extension ToolExecutor {
  func complete(_ session: SessionID, _ request: CompletionRequest) async throws -> String {
    try await refuseUnlessLive(session)
    let catalog: ProviderCatalog
    do {
      if let completionCatalog { catalog = try await completionCatalog() }
      else {
        let bytes = try await owner.capabilityDocument(ModelsDocument.spacePath)
        let groups = try await owner.capabilityDocument(ModelsDocument.groupPath)
        catalog = ProviderCatalog(document: try ModelsDocument(json: bytes ?? Data(), groupsJSON: groups), credentials: credentials)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      throw CompletionError(code: "providerNotConfigured", message: "The /models.json catalog is missing, unreadable or malformed.")
    }
    let specifier: ModelSpecifier
    do {
      if catalog.document.groups[request.provider] != nil {
        throw CatalogError.unsupportedTarget(request.provider)
      }
      specifier = try catalog.defaultSpecifier(provider: request.provider, model: request.model)
      try catalog.validate(specifier)
    } catch let error as CatalogError {
      switch error {
      case .unsupportedTarget:
        throw CompletionError(code: "unsupportedTarget", message: "Model groups are supported only by sessions; complete requires a concrete provider/model.")
      case .unknownProvider, .unknownModel:
        throw CompletionError(code: "unknownModel", message: "The requested provider/model is not in /models.json.")
      default: throw CompletionError(code: "providerNotConfigured", message: "The requested model configuration is invalid.")
      }
    }
    let baseURL = catalog.document.providers[request.provider]!.baseURL
    guard ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""), baseURL.host != nil,
          baseURL.user == nil, baseURL.password == nil
    else { throw CompletionError(code: "providerNotConfigured", message: "The requested provider needs an HTTP(S) baseURL without embedded credentials.") }
    if request.schema != nil, request.provider == "deepseek", catalog.document.providers[request.provider]?.dialect == .anthropic {
      throw CompletionError(code: "unsupportedSchema", message: "DeepSeek's Anthropic dialect does not support JSON schema output.")
    }
    let resolved: ResolvedModel
    do { resolved = try await catalog.resolve(specifier, session: session) }
    catch {
      if case .cancelled = error { throw CancellationError() }
      if case .invalidInput = error {
        throw CompletionError(code: "providerNotConfigured", message: "The requested provider's credentials or authentication configuration are unavailable or incompatible.")
      }
      throw CompletionError(code: "inferenceFailed", message: "The requested provider could not be resolved.")
    }
    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var continuousClock
    let clock = AnyClock(continuousClock)
    let timestamp = date.now
    let started = clock.now
    var usage: Usage?
    var servedModel: String?
    var firstEvent: Duration?
    var completed: AssistantMessage?
    var failure: InferenceError?
    let options = RequestOptions(maxTokens: resolved.budget.maxOutput, reasoning: specifier.effort == "none" && resolved.endpoint is any AnthropicMessagesEndpoint ? .none : .effort(specifier.effort), outputSchema: request.schema)
    for await event in resolved.endpoint.runInference(context: request.context, options: options, mediaResolver: nil) {
      if firstEvent == nil, case .success = event { firstEvent = started.duration(to: clock.now) }
      switch event {
      case let .failure(error): failure = error
      case let .success(.usage(value, model, _)): usage = value; servedModel = model
      case let .success(.done(message, metadata)):
        completed = message; usage = metadata.usage; servedModel = metadata.servedModel ?? servedModel
      default: break
      }
      if failure != nil { break }
    }
    if failure == nil, completed == nil { failure = .cancelled }
    if let completed, failure == nil {
      if completed.content.contains(where: { if case .toolCall = $0 { true } else if case .hostedTool = $0 { true } else { false } }) {
        failure = .malformedModelMessage(message: "Completion returned unsupported tool content.", reason: nil)
      } else if request.schema != nil, JSONValue.parse(completionText(completed)) == nil {
        failure = .malformedModelMessage(message: "Structured completion returned invalid JSON.", reason: nil)
      }
    }
    let outcome = InferenceMetric.classify(failure)
    let metric = InferenceMetric(
      timestamp: timestamp,
      session: session,
      provider: specifier.provider,
      model: specifier.model,
      servedModel: servedModel,
      effort: specifier.effort,
      outcome: outcome.outcome,
      errorKind: outcome.kind,
      status: outcome.status,
      ttftMs: firstEvent?.completionMilliseconds,
      durationMs: started.duration(to: clock.now).completionMilliseconds,
      usage: usage,
    )
    try await owner.recordCompletion(metric)
    if let failure {
      if case .cancelled = failure { throw CancellationError() }
      throw CompletionError(code: "inferenceFailed", message: "The requested model's inference failed; no fallback was attempted.")
    }
    return completionText(completed!)
  }
}

private extension Duration {
  var completionMilliseconds: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}

private func completionText(_ message: AssistantMessage) -> String {
  message.content.compactMap { if case let .text(text) = $0 { text.text } else { nil } }.joined()
}
