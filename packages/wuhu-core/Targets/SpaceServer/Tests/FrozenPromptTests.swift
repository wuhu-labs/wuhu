import struct Credentials.CredentialResolver
import Dependencies
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
@Suite struct FrozenPromptTests {
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
          // Every request of one turn carries the same prompt; that prompt.
          func turn(_ id: SessionID) async throws -> String {
            let start = tap.count
            try await harness.deliver("hello", to: id)
            try await until("\(id.rawValue) answers and settles", timeout: .seconds(60)) {
              guard tap.count > start else { return false }
              return try await harness.store.record(id).work == .noWork
            }
            let prompts = tap.since(start)
            #expect(Set(prompts).count == 1, "one prompt per turn")
            let prompt = try #require(prompts.first)
            #expect(prompt.contains("Your session id is \(id.rawValue) and"))
            return prompt
          }

          let firstPrompt = try await turn(first)
          let secondPrompt = try await turn(second)
          let shared = try sharedPart(firstPrompt, before: "Your session id is ")
          #expect(shared == (try sharedPart(secondPrompt, before: "Your session id is ")))
          #expect(shared.contains("root manual") && shared.hasSuffix("- review — Review things (/.agents/skills/review/SKILL.md)"))
          #expect(!shared.contains(first.rawValue) && !shared.contains(second.rawValue))

          try await edit(space, first, "edited")
          #expect(try await turn(first) == firstPrompt, "an edit after creation waits for a compaction")

          let head = GenerationHead(id: UUID(), timestamp: Date(), summary: "compacted", snapshot: .init())
          _ = try await harness.store.writeCompaction(first, head: head, kept: nil)
          let compacted = try await turn(first)
          #expect(compacted != firstPrompt)
          #expect(compacted.contains("root edited") && compacted.contains("home edited"))
          #expect(try await turn(second) == secondPrompt, "another session's compaction leaves it alone")
        }
      }
    }
  }
}

// Everything before the identity line, which opens the session's own part.
private func sharedPart(_ prompt: String, before identity: String) throws -> Substring {
  let line = try #require(prompt.range(of: "\n\n" + identity))
  return prompt[..<line.lowerBound]
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

// The provider: keeps each request's system prompt and answers every one with
// a short final answer.
private final class PromptTap: Sendable {
  private let prompts = Mutex<[String]>([])

  var count: Int { prompts.withLock { $0.count } }

  func since(_ start: Int) -> [String] {
    prompts.withLock { Array($0[start...]) }
  }

  var client: FetchClient {
    FetchClient { request in
      let data = try await request.body?.data() ?? Data()
      let body = JSONValue.parse(String(decoding: data, as: UTF8.self))
      if let prompt = body?.object?["input"]?.array?.first?.object?["content"]?.stringValue {
        self.prompts.withLock { $0.append(prompt) }
      }
      return Response(status: .ok, headers: HTTPFields(), body: .bytes(Data(finalAnswer.utf8), contentType: "text/event-stream"))
    }
  }
}

private let finalAnswer = """
event: response.output_item.done
data: {"type":"response.output_item.done","item":{"id":"msg_1","type":"message","status":"completed","content":[{"type":"output_text","annotations":[],"logprobs":[],"text":"ok"}],"phase":"final_answer","role":"assistant"},"output_index":0,"sequence_number":1}

event: response.completed
data: {"type":"response.completed","response":{"id":"resp_1","object":"response","status":"completed","model":"gpt-5.6-luna","output":[{"id":"msg_1","type":"message","status":"completed","content":[{"type":"output_text","annotations":[],"logprobs":[],"text":"ok"}],"phase":"final_answer","role":"assistant"}],"usage":{"input_tokens":10,"input_tokens_details":{"cached_tokens":0},"output_tokens":1,"output_tokens_details":{"reasoning_tokens":0},"total_tokens":11}},"sequence_number":2}


"""
