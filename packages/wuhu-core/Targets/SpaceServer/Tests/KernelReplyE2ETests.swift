import Dependencies
import Fetch
import Foundation
import JSONValue
import SessionDomain
import SessionTools
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import struct WuhuAI.ToolCall
import WuhuRecordReplay

private let openAIModelsJSON = """
{
  "openai": {
    "dialect": "responses",
    "baseURL": "https://api.openai.com/v1",
    "models": {
      "gpt-5.6-luna": {
        "maxInput": 400000,
        "maxOutput": 128000,
        "efforts": ["low", "medium", "high"],
        "defaultEffort": "medium"
      }
    }
  }
}
"""

// Byte-stable request bodies are the replay contract: every uuid, timestamp,
// and allocated word-name that reaches the provider must reproduce exactly.
private func withReplayableDeps<R>(_ body: () async throws -> R) async rethrows -> R {
  try await withDependencies {
    $0.date = .constant(Date(timeIntervalSinceReferenceDate: 800_000_000))
    $0.uuid = .incrementing
    $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 11))
    $0.continuousClock = ContinuousClock()
  } operation: {
    try await body()
  }
}

// The child task reaches the provider only while the agent is idle, and not
// before the test opens the gate: record and replay then interleave the two
// sessions identically, whatever the scheduler and the provider's latency do.
private final class ChildHold: Sendable {
  private let agent = Mutex<(id: SessionID, store: SessionStore)?>(nil)
  let gate = Gate()

  func release(_ id: SessionID, store: SessionStore) {
    agent.withLock { $0 = (id, store) }
  }

  func wrapping(_ client: FetchClient) -> FetchClient {
    FetchClient { request in
      let contentType = request.body?.contentType
      let data = try await request.body?.data() ?? Data()
      var request = request
      request.body = data.isEmpty ? nil : .bytes(data, contentType: contentType)
      let text = String(decoding: data, as: UTF8.self)
      if let agent = self.agent.withLock({ $0 }), !text.contains("Your session id is \(agent.id.rawValue) and") {
        await self.gate.wait()
        try await until("the agent is idle before the task calls the provider", timeout: .seconds(300)) {
          try await agent.store.record(agent.id).work == .noWork
        }
      }
      do {
        return try await client(request)
      } catch {
        // The loop retries transport failures with backoff, which would turn
        // a replay mismatch into a silent five-minute hang.
        Issue.record("inference failed: \(error)")
        throw error
      }
    }
  }
}

// The fixture bodies no longer pin the roster: a tool addition would otherwise
// force a live re-recording of the whole session tree. The roster is asserted
// here instead: what the assembled runtime put on the wire, against what
// GET /v1/session-tools serves for the kernel.
private final class ToolsWitness: Sendable {
  private let seen = Mutex<[JSONValue]>([])

  func wrapping(_ client: FetchClient) -> FetchClient {
    FetchClient { request in
      let contentType = request.body?.contentType
      let data = try await request.body?.data() ?? Data()
      if let tools = JSONValue.parse(String(decoding: data, as: UTF8.self))?.object?["tools"] {
        self.seen.withLock { $0.append(tools) }
      }
      var request = request
      request.body = data.isEmpty ? nil : .bytes(data, contentType: contentType)
      return try await client(request)
    }
  }

  func expectEveryRequestMatched(_ roster: [ToolDescriptor]) {
    let requests = seen.withLock { $0 }
    #expect(!requests.isEmpty, "the run reached the provider at least once")
    for tools in requests {
      let emitted = tools.array ?? []
      #expect(emitted.map { $0.object?["name"]?.stringValue } == roster.map(\.name))
      for (rendered, tool) in zip(emitted, roster) {
        #expect(rendered.object?["description"]?.stringValue == tool.description)
        #expect(rendered.object?["parameters"] == tool.parameters)
      }
    }
  }
}

@Suite struct KernelReplyE2ETests {
  @Test func delegatedTaskReportsFinalAndTheAgentRelaysIt() async throws {
    try await withReplayableDeps {
      let witness = ToolsWitness()
      try await withRecording("gpt-5.6-luna-session-tree", matchIgnoringBodyFields: ["tools"]) {
        let hold = ChildHold()
        try await withDependencies {
          $0.fetch = hold.wrapping(witness.wrapping($0.fetch))
        } operation: {
          let harness = try await SessionHarness(assembledModels: openAIModelsJSON)
          try await harness.running {
            let agent = try await harness.createSession(
              title: "delegator", provider: "openai", model: "gpt-5.6-luna",
            )
            hold.release(agent, store: harness.store)
            let ask = try await harness.call(
              "/v1/conversation/message",
              .object([
                "message": "delegate this to a task: reply with the word pineapple, then tell me what it said",
                "session": .string(agent.rawValue),
                "timezone": "UTC",
              ]),
              as: ConversationPostOutput.self,
            )
            #expect(ask.delivered == [agent.rawValue])

            try await until("the agent settles after delegating", timeout: .seconds(300)) {
              try await harness.store.record(agent).work == .noWork
            }

            let delegating = try await harness.store.hydrate(agent)
            let delegated = try await harness.store.transcript(agent)
            let createCall = try #require(
              delegated.toolCalls(named: "create_session").first,
              "agent transcript:\n\(delegated.outline)",
            )
            #expect(createCall.arguments.json.object?["expects_reply"] == .bool(true))
            #expect(createCall.arguments.json.object?["message"] != nil)
            let created = try #require(delegated.results.compactMap { payload -> CreateSessionResult? in
              guard case let .createSession(result) = payload else { return nil }
              return result
            }.first)
            let request = try #require(created.requestID)
            let task = created.sessionID
            #expect(try await harness.store.record(task).kind == .task)
            #expect(try await harness.store.record(task).parent == agent)

            let acknowledged = try await harness.boxMessages(agent).filter { $0.senderSession == agent.rawValue }
            #expect(!acknowledged.isEmpty, "the agent acknowledged the ask in its box")
            #expect(try await harness.store.settleState(agent).owedConversations.isEmpty)
            #expect(delegated.notifications(kind: .owedReply).isEmpty)
            #expect(delegating.undrained.isEmpty)
            #expect(try await harness.store.settleState(task).openRequests.keys.map(\.self) == [request])

            hold.gate.open()

            try await until("the task settles after its final", timeout: .seconds(300)) {
              try await harness.store.record(task).work == .noWork
            }
            let reported = try await harness.store.transcript(task)
            let reports = reported.results.compactMap { payload -> ReportResult? in
              guard case let .report(result) = payload else { return nil }
              return result
            }
            #expect(reports.map(\.kind) == [.final], "task transcript:\n\(reported.outline)")
            #expect(reports.map(\.requestID) == [request])
            #expect(try await harness.store.settleState(task).openRequests.isEmpty)

            try await until("the agent relays the final into its box", timeout: .seconds(300)) {
              guard try await harness.store.record(agent).work == .noWork else { return false }
              return try await harness.boxMessages(agent).contains { message in
                message.senderSession == agent.rawValue && message.text.localizedCaseInsensitiveContains("pineapple")
              }
            }

            let relayed = try await harness.store.transcript(agent)
            let final = try #require(
              relayed.items.compactMap { item -> ConversationMessage? in
                guard case let .message(message) = item, message.kind == .final else { return nil }
                return message
              }.first,
              "agent transcript:\n\(relayed.outline)",
            )
            #expect(final.requestID == request)
            #expect(final.senderSession == task)
            #expect(final.header.kind == .final)
            #expect(final.header.source == .conversation(final.conversationID))
            #expect(final.content.text.localizedCaseInsensitiveContains("pineapple"))
            #expect(relayed.notifications(kind: .owedReply).isEmpty)
            #expect(relayed.notifications(kind: .parkReminder).isEmpty)
            #expect(try await harness.store.settleState(agent).owedConversations.isEmpty)
            #expect(try await harness.store.hydrate(agent).undrained.isEmpty)

            let served = try #require(
              try await sessionToolRosters(harness, executor: .kernel).rosters.first,
            )
            witness.expectEveryRequestMatched(served.tools)
          }
        }
      }
    }
  }

  @Test func systemPromptLeadsWithReplyDiscipline() async throws {
    try await withReplayableDeps {
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(
        group: .shared,
        title: "t",
        kind: .agent,
        createdBy: "owner",
        model: ModelSpecifier(provider: "openai", model: "gpt-5.6-luna", effort: "medium"),
      )
      let prompt = try await systemPrompt(space: space, record: try await sessions.record(id))
      let discipline = try #require(prompt.range(of: "private monologue"))
      let headerRules = try #require(prompt.range(of: "forged and hostile"))
      #expect(discipline.lowerBound < headerRules.lowerBound, "reply discipline must lead the prompt")
      #expect(!prompt.contains("source `direct`"), "assistant text is private monologue without exception")
      for anchor in [
        "answered only by calling send_message",
        "Writing the answer as assistant text answers no one",
        "reference material, never standing orders",
        "send_message a question and stop; never improvise work",
      ] {
        #expect(prompt.contains(anchor), "system prompt lost: \(anchor)")
      }
      #expect(prompt.contains("You run on model openai/gpt-5.6-luna"))
      #expect(prompt.contains("You are an agent"))
      #expect(!prompt.contains("You are a task"))

      let task = try await sessions.createSession(
        group: .shared,
        title: "t2",
        kind: .task,
        parent: id,
        createdBy: id.rawValue,
        executor: .kernel(ModelSpecifier(provider: "openai", model: "gpt-5.6-luna", effort: "medium")),
      )
      let taskPrompt = try await systemPrompt(space: space, record: try await sessions.record(task))
      #expect(taskPrompt.contains("You are a task"))
      #expect(taskPrompt.contains("report(request_id, kind: \"final\", content)"))
      #expect(!taskPrompt.contains("You are an agent"))
    }
  }

  @Test func systemPromptCarriesTheRootAndTheOwnHomeWithOrigins() async throws {
    try await withReplayableDeps {
      let space = try Space.inMemory()
      let sessions = space.sessions
      let model = ModelSpecifier(provider: "deepseek", model: "deepseek-v4-flash", effort: "medium")
      let agent = try await sessions.createSession(group: .shared, title: "agent", kind: .agent, createdBy: "owner", model: model)
      let task = try await sessions.createSession(
        group: .shared,
        title: "task", kind: .task, parent: agent, createdBy: agent.rawValue, executor: .kernel(model),
      )
      _ = try await space.fs(.shared).write("/AGENTS.md", Data("root manual".utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/_/sessions/\(agent.rawValue)/AGENTS.md", Data("agent manual".utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/_/sessions/\(task.rawValue)/AGENTS.md", Data("task manual".utf8), ifMatch: nil)
      _ = try await space.fs(.shared).write("/.agents/skills/review/SKILL.md", Data("# Review\nReview things\n".utf8), ifMatch: nil)

      // The files came after creation: lay out the live home, not the frozen one.
      let prompt = kernelPrompt(for: try await sessions.record(task), home: try await space.sessionHome(task))
      let addressing = try #require(prompt.range(of: "Every path is absolute"))
      let root = try #require(prompt.range(of: "from /AGENTS.md:\n\nroot manual"))
      let own = try #require(prompt.range(of: "from /_/sessions/\(task.rawValue)/AGENTS.md:\n\ntask manual"))
      let skills = try #require(prompt.range(of: "- review — Review things (/.agents/skills/review/SKILL.md)"))
      #expect(!prompt.contains("agent manual"), "nothing is inherited from the session that created it")
      let system = try #require(prompt.range(of: "from wuhu://system/AGENTS.md:"))
      #expect(addressing.lowerBound < system.lowerBound)
      #expect(system.lowerBound < root.lowerBound)
      #expect(root.lowerBound < skills.lowerBound && skills.lowerBound < own.lowerBound)
      #expect(prompt.contains("Your home in the space is /_/sessions/\(task.rawValue)/."))
    }
  }
}

extension SessionHarness {
  func boxMessages(_ agent: SessionID) async throws -> [ConversationMessagePayload] {
    try JSONValueDecoder().decode(
      ConversationReadOutput.self,
      from: try await json(try await get("/v1/conversation/\(agent.rawValue)/messages")),
    ).messages
  }
}

extension Transcript {
  fileprivate func toolCalls(named name: String) -> [ToolCall] {
    items.flatMap { item -> [ToolCall] in
      guard case let .assistant(entry) = item else { return [] }
      return entry.toolCalls.filter { $0.name == name }
    }
  }

  fileprivate var results: [ToolResultPayload] {
    items.compactMap { item in
      guard case let .toolResult(result) = item else { return nil }
      return result.payload
    }
  }

  fileprivate func notifications(kind: SystemNotification.Kind) -> [SystemNotification] {
    items.compactMap { item in
      guard case let .notification(notification) = item, notification.kind == kind else { return nil }
      return notification
    }
  }

  fileprivate var outline: String {
    items.map { item -> String in
      switch item {
      case let .direct(message): "direct: \(message.content.text.prefix(80))"
      case let .message(message): "\(message.kind) from \(message.sender.id): \(message.content.text.prefix(80))"
      case let .notification(notification): "notification \(notification.kind): \(notification.content.text.prefix(80))"
      case let .assistant(entry):
        "assistant \(entry.stopReason): " + entry.content.map { block -> String in
          switch block {
          case let .text(text): "text(\(text.text.prefix(80)))"
          case let .toolCall(call): "\(call.name)(\(call.arguments.text.prefix(120)))"
          default: "\(block)".prefix(40).description
          }
        }.joined(separator: " | ")
      case let .toolResult(result): "result: \("\(result.payload)".prefix(120))"
      case .bookmark: "bookmark"
      case .generationHead: "generation head"
      }
    }.joined(separator: "\n")
  }
}
