import struct Credentials.CredentialResolver
import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import HTTPTypes
import JSONValue
import Scratch
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

// Both executors take their prompt through their real call sites, the
// kernel's inference and Claude Code's launch, never a test-side copy of the
// wiring. Were either to read the live home, an edit after creation would
// show up and these fail.
@Suite(.deterministicDependencies) struct FrozenPromptTests {
  private func edit(_ space: Space, _ id: SessionID, _ tag: String) async throws {
    _ = try await space.fs(.shared).write("/AGENTS.md", Data("root \(tag)".utf8), ifMatch: nil)
    _ = try await space.fs(.shared).write("\(SessionHome.path(of: id))/AGENTS.md", Data("home \(tag)".utf8), ifMatch: nil)
  }

  private func seed(_ space: Space) async throws {
    _ = try await space.fs(.shared).write("/AGENTS.md", Data("root manual".utf8), ifMatch: nil)
    _ = try await space.fs(.shared).write("/.agents/skills/review/SKILL.md", Data("# Review\nReview things\n".utf8), ifMatch: nil)
  }

  @Test func theKernelSendsTheFrozenPromptUntilACompaction() async throws {
    try await withSessionDeps {
      let tap = PromptTap()
      try await withDependencies {
        $0.fetch = tap.client
      } operation: {
        let harness = try await SessionHarness(assembledModels: responsesModels)
        let space = harness.space
        try await seed(space)
        let first = try await harness.createSession(title: "first", provider: "openai", model: "gpt-5.6-luna")
        let second = try await harness.createSession(title: "second", provider: "openai", model: "gpt-5.6-luna")
        try await harness.running {
          // Every request of one turn carries the same prompt; that prompt:
          // the system text, the group's instructions, the session's own.
          func turn(_ id: SessionID) async throws -> [String] {
            let start = tap.count
            try await harness.deliver("hello", to: id)
            try await until("\(id.rawValue) answers and settles", timeout: .seconds(60)) {
              guard tap.count > start else { return false }
              return try await harness.store.settledWork(id)
            }
            let prompts = tap.since(start)
            #expect(Set(prompts).count == 1, "one prompt per turn")
            let prompt = try #require(prompts.first)
            try #require(prompt.count == 3, "\(prompt.dropFirst())")
            #expect(prompt[2].hasPrefix("<session-instructions>") && prompt[2].contains("Your session id is \(id.rawValue) and"))
            return prompt
          }

          let firstPrompt = try await turn(first)
          let secondPrompt = try await turn(second)
          #expect(firstPrompt.prefix(2) == secondPrompt.prefix(2), "the system text and the group's instructions are every session's")
          #expect(firstPrompt[1].hasPrefix("<group-instructions>") && firstPrompt[1].contains("root manual"))
          #expect(firstPrompt[1].hasSuffix("- review — Review things (/.agents/skills/review/SKILL.md)\n</group-instructions>"))
          #expect(!firstPrompt[0].contains("root manual"))
          #expect(!firstPrompt.prefix(2).contains { $0.contains(first.rawValue) || $0.contains(second.rawValue) })

          try await edit(space, first, "edited")
          _ = try await harness.store.setTitle(first, to: "renamed")
          #expect(try await turn(first) == firstPrompt, "an edit or a rename within a generation waits for a compaction")

          tap.foldNext()
          try await harness.deliver("fold", to: first)
          try await until("first compacts", timeout: .seconds(60)) {
            guard try await harness.store.generationState(first).generation == 1 else { return false }
            return try await harness.store.settledWork(first)
          }
          let compacted = try await turn(first)
          #expect(compacted[0] == firstPrompt[0], "the system text is the binary's: a compaction renders the same")
          #expect(compacted[1].contains("root edited") && compacted[2].contains("home edited"))
          #expect(compacted[2].contains("your title is \"renamed\""))
          #expect(try await turn(second) == secondPrompt, "another session's compaction leaves it alone")
        }
      }
    }
  }
}

private let responsesModels = """
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

// The provider: keeps each request's system text and the instruction messages
// that open it, and answers every one with a short final answer.
private final class PromptTap: Sendable {
  private let prompts = Mutex<[[String]]>([])
  private let folds = Mutex(false)

  /// The next request is answered with a `compact` call.
  func foldNext() { folds.withLock { $0 = true } }

  var count: Int { prompts.withLock { $0.count } }

  func since(_ start: Int) -> [[String]] {
    prompts.withLock { Array($0[start...]) }
  }

  var client: FetchClient {
    FetchClient { request in
      let data = try await request.body?.data() ?? Data()
      let body = JSONValue.parse(String(decoding: data, as: UTF8.self))
      if let input = body?.object?["input"]?.array, let system = input.first?.object?["content"]?.stringValue {
        let opening = input.dropFirst().prefix(2).compactMap { $0.object?["content"]?.array?.first?.object?["text"]?.stringValue }
        self.prompts.withLock { $0.append([system] + opening.filter { $0.hasSuffix("-instructions>") }) }
      }
      let fold = self.folds.withLock { fold in defer { fold = false }; return fold }
      return Response(status: .ok, headers: HTTPFields(), body: .bytes(Data((fold ? compactCall : finalAnswer).utf8), contentType: "text/event-stream"))
    }
  }
}

private let compactCall: String = {
  let call: JSONValue = ["type": "function_call", "call_id": "call_fold", "name": "compact", "arguments": .string((["summary": "folded"] as JSONValue).jsonString())]
  let events: [JSONValue] = [
    ["type": "response.output_item.added", "item": call],
    ["type": "response.output_item.done", "item": call],
    ["type": "response.completed", "response": ["status": "completed", "usage": ["input_tokens": 10, "output_tokens": 5, "total_tokens": 15]]],
  ]
  return events.map { "data: " + $0.jsonString() + "\n\n" }.joined()
}()

private let finalAnswer = """
event: response.output_item.done
data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","status":"completed","content":[{"type":"output_text","annotations":[],"logprobs":[],"text":"ok"}],"phase":"final_answer","role":"assistant"},"output_index":0,"sequence_number":1}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_1","object":"response","status":"completed","model":"gpt-5.6-luna","output":[{"id":"msg_1","type":"message","status":"completed","content":[{"type":"output_text","annotations":[],"logprobs":[],"text":"ok"}],"phase":"final_answer","role":"assistant"}],"usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":0},"output_tokens":1,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":11}},"sequence_number":2}


"""
