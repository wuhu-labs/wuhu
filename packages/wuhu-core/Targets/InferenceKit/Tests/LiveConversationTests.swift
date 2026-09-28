import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import FetchURLSession
import Foundation
@testable import InferenceKit
import Scratch
import SessionDomain
import Testing
import WuhuAI

// Live scripted conversation through the full catalog -> executor path.
// Gated: runs only with WUHU_LIVE=1 and the provider's API key in the
// environment; otherwise it is a deterministic no-op.
private let liveCases: [(provider: String, model: String)] = [
  ("anthropic", "claude-sonnet-5"),
  ("openai", "gpt-5.4"),
  ("deepseek", "deepseek-v4-pro"),
]

@Suite struct LiveConversationTests {
  @Test(arguments: liveCases.map(\.provider))
  func scriptedConversation(provider: String) async throws {
    guard ProcessInfo.processInfo.environment["WUHU_LIVE"] == "1" else { return }
    let model = liveCases.first { $0.provider == provider }!.model

    let catalog = ProviderCatalog(
      document: try ModelsDocument(json: fixtureJSON),
      credentials: .environmentOnly,
    )
    let hub = AttemptHub()
    let scratch = try ScratchFolder("wuhu-live-attempts")
    defer { scratch.remove() }
    let logDirectory = ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"]
      .map { URL(filePath: $0).appending(path: "live-attempts") } ?? scratch.url
    let executor = InferenceExecutor(
      session: SessionID("live-session"),
      model: try await catalog.resolve(.init(provider: provider, model: model, effort: "high"), session: SessionID("live-conversation-tests")),
      systemPrompt: "You are a Wuhu session agent. Answer in at most two sentences.",
      tools: [],
      hub: hub,
      log: AttemptLogConfig(directory: logDirectory),
    )
    let sender = Sender(id: "morgan", timeZone: TimeZone(identifier: "Asia/Shanghai")!)

    try await withDependencies {
      $0.fetch = .urlSession()
      $0.uuid = UUIDGenerator { UUID() }
      $0.date = DateGenerator { Date() }
      $0.continuousClock = ContinuousClock()
    } operation: {
      var transcript = Transcript()
      func send(_ text: String) async throws -> String {
        transcript.append(.direct(.init(id: UUID(), sender: sender, timestamp: Date(), content: .init(text: text))))
        let attemptID = UUID()
        let reply = try await executor.run(attemptID: attemptID, transcript: transcript, mode: .normal)
        transcript.appendAssistant(reply.message, id: attemptID, metadata: reply.metadata)
        let answer = reply.message.content.compactMap { block -> String? in
          if case let .text(t) = block { return t.text }
          return nil
        }.joined()
        print("[\(provider)/\(model)] user: \(text)")
        print("[\(provider)/\(model)] assistant: \(answer)")
        print("[\(provider)/\(model)] usage: \(reply.metadata.usage.map(String.init(describing:)) ?? "none")")
        return answer
      }

      let first = try await send("Remember this codeword: heliotrope. What provider are you running on?")
      #expect(!first.isEmpty)
      let second = try await send("What was the codeword?")
      #expect(second.localizedCaseInsensitiveContains("heliotrope"))
      #expect(transcript.items.count == 4)
    }
  }
}
