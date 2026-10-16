#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CProcessIdentity
import struct Credentials.CredentialResolver
import enum InferenceKit.CatalogError
import struct InferenceKit.ModelsDocument
import struct InferenceKit.ProviderCatalog
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.SessionID
import WuhuAI

public enum MinimalAgent {
  static let reminder = "Your reply had no tool call. Keep working with read, write and bash, or call complete with your result."

  /// Runs the agent described by `request` (the stdin JSON document) until it calls `complete`, and returns that result.
  public static func run(request text: String, log: AgentLog?, workingDirectory: String) async throws(AgentError) -> String {
    // The shell runs as the same user: unreadable /proc/<pid>/environ and memory keep the session token this process inherited out of its reach.
    let denied = process_deny_inspection()
    guard denied == 0 else { throw AgentError(.isolation, "cannot make the agent non-dumpable: errno \(denied)") }
    let request = try AgentRequest.decode(text)
    let mask = Masker(credential: request.credential, environment: ProcessInfo.processInfo.environment)
    let directory = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    let endpoint = try await resolve(request, mask: mask)
    let options = RequestOptions(maxTokens: endpoint.maxOutput, reasoning: endpoint.specifier.effort == "none" && endpoint.model is any AnthropicMessagesEndpoint ? .none : .effort(endpoint.specifier.effort))
    var transcript = try Transcript(log.map { log in
      switch log {
      case let .new(path): .new(URL(fileURLWithPath: path, relativeTo: directory).path)
      case let .resume(path): .resume(URL(fileURLWithPath: path, relativeTo: directory).path)
      }
    })
    try transcript.closeInterruptedCalls()
    try transcript.append(mask(.user(UserMessage(content: [.text(request.task)]))))
    let toolbox = Toolbox(directory: directory, bashTimeoutSeconds: request.bashTimeoutSeconds, secrets: mask.secrets)
    var reminded = false
    for _ in 0 ..< request.maxTurns {
      let raw: AssistantMessage
      do {
        raw = try await endpoint.model.inference(context: Context(systemPrompt: request.system, messages: transcript.messages, tools: Toolbox.definitions), options: options).collect()
      } catch {
        throw AgentError(.inference, String(mask(String(describing: error)).prefix(4096)))
      }
      guard case let .assistant(reply) = mask(.assistant(raw)) else { preconditionFailure("masking keeps the role") }
      try transcript.append(.assistant(reply))
      let calls = reply.content.compactMap { if case let .toolCall(call) = $0 { call } else { nil } }
      if calls.isEmpty {
        guard !reminded else { throw AgentError(.noComplete, "two replies in a row without a tool call") }
        reminded = true
        try transcript.append(.user(UserMessage(content: [.text(reminder)])))
        continue
      }
      reminded = false
      if let complete = calls.first(where: { $0.name == Toolbox.complete }) {
        if let result = complete.arguments.json.object?["result"]?.stringValue {
          for call in calls {
            let done = call.id == complete.id
            try transcript.append(.toolResult(ToolResultMessage(toolCallId: call.id, content: [.text(done ? "completed" : "not run: complete ends the run")], isError: !done)))
          }
          return result
        }
      }
      for call in calls {
        let result = call.name == Toolbox.complete
          ? ToolResultMessage(toolCallId: call.id, content: [.text("complete needs a string \"result\"")], isError: true)
          : await toolbox.run(call)
        try transcript.append(mask(.toolResult(result)))
      }
    }
    throw AgentError(.turnBudgetExhausted, "\(request.maxTurns) turns ended without complete")
  }

  private struct Endpoint {
    var model: any ModelEndpoint
    var specifier: ModelSpecifier
    var maxOutput: Int
  }

  private static func resolve(_ request: AgentRequest, mask: Masker) async throws(AgentError) -> Endpoint {
    guard let slash = request.model.firstIndex(of: "/") else { throw AgentError(.invalidRequest, "model must be provider/model") }
    let providerID = String(request.model[..<slash])
    let modelID = String(request.model[request.model.index(after: slash)...])
    let credential = request.credential.provider
    let catalog = ProviderCatalog(document: ModelsDocument(providers: [providerID: request.provider]), credentials: CredentialResolver { _ in credential })
    let specifier: ModelSpecifier
    do {
      specifier = try request.effort.map { ModelSpecifier(provider: providerID, model: modelID, effort: $0) } ?? catalog.defaultSpecifier(provider: providerID, model: modelID)
      try catalog.validate(specifier)
    } catch let error as CatalogError { throw AgentError(.invalidRequest, error.description) }
    catch { throw AgentError(.invalidRequest, "\(error)") }
    do {
      let resolved = try await catalog.resolve(specifier, session: SessionID(UUID().uuidString))
      return Endpoint(model: resolved.endpoint, specifier: specifier, maxOutput: resolved.budget.maxOutput)
    } catch {
      throw AgentError(.invalidRequest, mask(String(describing: error)))
    }
  }
}
