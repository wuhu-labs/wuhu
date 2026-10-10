import Fetch
import Foundation
import JSONValue
import SessionDomain
import struct SpaceContract.ConversationReadOutput
import struct SpaceContract.SessionEntryOutput
import struct SpaceContract.SessionLogItem
import struct SpaceContract.SessionLogOutput
import SpaceCore
@testable import SpaceServer
import Testing
import WuhuAI

private func decodeLog(_ response: Response) async throws -> SessionLogOutput {
  let text = try await response.text()
  #expect(response.status == .ok, Comment(rawValue: text))
  return try JSONValueDecoder().decode(SessionLogOutput.self, from: try #require(JSONValue.parse(text)))
}

private func decodeEntry(_ response: Response) async throws -> SessionEntryOutput {
  let text = try await response.text()
  #expect(response.status == .ok, Comment(rawValue: text))
  return try JSONValueDecoder().decode(SessionEntryOutput.self, from: try #require(JSONValue.parse(text)))
}

private func errorCode(_ response: Response) async throws -> String? {
  try await json(response).object?["code"]?.stringValue
}

private func transcriptItem(_ item: JSONValue) throws -> TranscriptItem {
  try JSONDecoder().decode(TranscriptItem.self, from: Data(item.jsonString().utf8))
}

private func messageText(_ item: SessionLogItem) throws -> String? {
  guard case let .message(message) = try transcriptItem(item.item) else { return nil }
  return message.content.text
}

private func toolHeavyKernelSession(_ harness: SessionHarness, rounds: Int) async throws -> SessionID {
  let id = try await harness.createSession()
  for round in 0 ..< rounds {
    _ = try await harness.store.enqueue(id, input: .message(ConversationMessage(
      id: UUID(),
      messageID: MessageID(UUID().uuidString),
      conversationID: ConversationID("ch1"),
      sender: Sender(id: "owner", timeZone: TimeZone(identifier: "UTC")!),
      timestamp: Date(),
      content: MessageContent(text: "msg \(round)"),
    )))
  }
  _ = try await harness.store.drainQueue(id)
  for call in 0 ..< rounds * 2 {
    _ = try await harness.store.appendAssistant(
      id,
      attemptID: UUID(),
      message: AssistantMessage(content: [
        .toolCall(ToolCall(id: "c\(call)", name: "exec", arguments: .object([:]))),
      ]),
      metadata: AssistantMessageMetadata(
        stopReason: .stop,
        usage: Usage(inputTokens: 1, outputTokens: 1, totalTokens: 10),
      ),
    )
    _ = try await harness.store.writeToolResult(id, ToolResultItem(
      id: UUID(),
      timestamp: Date(),
      provenance: .toolCall(ToolCallID("c\(call)")),
      payload: .exec(ExecResult(output: "out \(call)", exitCode: 0)),
    ))
  }
  return id
}

@Suite struct SessionLogRouteTests {
  @Test func kernelLogFiltersServerSideAndPaginatesPostFilter() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      // Raw rows: 1 generation head + 60 messages + 240 tool rows.
      let id = try await toolHeavyKernelSession(harness, rounds: 60)
      let path = "/v1/session/\(id.rawValue)/log"

      let narrative = try await decodeLog(harness.get(path, query: ["level": "1", "limit": "50"]))
      #expect(narrative.items.count == 50)
      #expect(try narrative.items.compactMap(messageText).count == 50, "tail-50 at L1 is 50 narrative items, not 50 raw rows")
      #expect(try messageText(try #require(narrative.items.first)) == "msg 10")
      #expect(try messageText(try #require(narrative.items.last)) == "msg 59")

      let defaultLevel = try await decodeLog(harness.get(path, query: ["limit": "50"]))
      #expect(defaultLevel.items.map(\.ref) == narrative.items.map(\.ref))

      let defaultLimit = try await decodeLog(harness.get(path, query: ["level": "3"]))
      #expect(defaultLimit.items.count == 50)

      let verbose = try await decodeLog(harness.get(path, query: ["level": "2", "limit": "500"]))
      #expect(verbose.items.count == 181)
      let everything = try await decodeLog(harness.get(path, query: ["level": "3", "limit": "500"]))
      #expect(everything.items.count == 301)

      #expect(try await harness.get(path, query: ["level": "9"]).status == .badRequest)
      #expect(try await harness.get(path, query: ["limit": "0"]).status == .badRequest)
      #expect(try await harness.get(path, query: ["limit": "501"]).status == .badRequest, "limit is capped server-side")
      #expect(try await harness.get("/v1/session/no-such-session/log").status == .notFound)
    }
  }

  @Test func kernelBeforePagesOlderItemsLevelIndependently() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await toolHeavyKernelSession(harness, rounds: 40)
      let path = "/v1/session/\(id.rawValue)/log"

      let all = try await decodeLog(harness.get(path, query: ["level": "1", "limit": "500"]))
      let cut = try #require(try all.items.first { try messageText($0) == "msg 30" }).ref
      let page = try await decodeLog(harness.get(path, query: ["level": "1", "limit": "10", "before": cut]))
      #expect(page.items.count == 10)
      #expect(try messageText(try #require(page.items.first)) == "msg 20")
      #expect(try messageText(try #require(page.items.last)) == "msg 29")

      // A ref minted at L3 cuts an L1 page: before is a stream position, not
      // a level-dependent index.
      let everything = try await decodeLog(harness.get(path, query: ["level": "3", "limit": "500"]))
      let toolCut = try #require(everything.items.last).ref
      let older = try await decodeLog(harness.get(path, query: ["level": "1", "limit": "500", "before": toolCut]))
      #expect(older.items.count == 41, "the generation head plus every message")
    }
  }

  @Test func kernelRefsRoundTripAndCompactionTrimsThem() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await toolHeavyKernelSession(harness, rounds: 3)
      let path = "/v1/session/\(id.rawValue)/log"

      let everything = try await decodeLog(harness.get(path, query: ["level": "3", "limit": "500"]))
      let last = try #require(everything.items.last)
      let entry = try await decodeEntry(harness.get("/v1/session/\(id.rawValue)/entry/\(last.ref)"))
      #expect(entry.item.item == last.item)
      guard case let .toolResult(result) = try transcriptItem(entry.item.item) else {
        Issue.record("the transcript tail is a tool result")
        return
      }
      #expect(result.payload == .exec(ExecResult(output: "out 5", exitCode: 0)))

      let parts = last.ref.split(separator: ":")
      #expect(parts.count == 3, "kernel refs are tag:generation:position")
      let tag = String(parts[0])
      #expect(tag == kernelRefTag(id.rawValue))
      let generation = String(parts[1])
      let unknown = try await harness.get("/v1/session/\(id.rawValue)/entry/\(tag):\(generation):9999")
      #expect(unknown.status == .notFound)
      #expect(try await errorCode(unknown) == "unknownRef")
      #expect(try await harness.get("/v1/session/\(id.rawValue)/entry/no-colon").status == .badRequest)
      #expect(try await harness.get("/v1/session/\(id.rawValue)/entry/99:0").status == .badRequest, "the old two-part form is malformed now")
      let future = try await harness.get("/v1/session/\(id.rawValue)/entry/\(tag):99:0")
      #expect(future.status == .notFound)
      let foreignTag = tag == "0000" ? "1111" : "0000"
      let foreign = try await harness.get("/v1/session/\(id.rawValue)/entry/\(foreignTag):\(generation):0")
      #expect(foreign.status == .notFound, "a ref minted for another session never resolves here")
      #expect(try await errorCode(foreign) == "unknownRef")
      let other = try await harness.createSession()
      let crossSession = try await harness.get("/v1/session/\(other.rawValue)/entry/\(last.ref)")
      #expect(crossSession.status == .notFound, "coincident generation:position in another session stays invisible")

      _ = try await harness.store.writeCompaction(
        id,
        head: GenerationHead(id: UUID(), timestamp: Date(), summary: "squashed", snapshot: StateSnapshot()),
        kept: nil,
      )
      let trimmed = try await harness.get("/v1/session/\(id.rawValue)/entry/\(last.ref)")
      #expect(trimmed.status == .gone)
      #expect(try await errorCode(trimmed) == "trimmedRef")
      let trimmedPage = try await harness.get(path, query: ["before": last.ref])
      #expect(trimmedPage.status == .gone)

      let fresh = try await decodeLog(harness.get(path, query: ["level": "1"]))
      let freshRef = try #require(fresh.items.first).ref
      let freshParts = freshRef.split(separator: ":")
      #expect(freshParts.count == 3)
      #expect(Int(freshParts[1]) == (Int(generation) ?? 0) + 1, "post-compaction refs live in the new generation")
    }
  }

  @Test func channelEntriesServeATailPage() async throws {
    try await withSessionDeps {
      let harness = try await SessionHarness()
      let id = try await harness.createSession()
      let sender = Sender(id: "owner", timeZone: TimeZone(identifier: "UTC")!)
      for index in 0 ..< 5 {
        _ = try await harness.store.post(
          .box(id),
          messageID: MessageID("m\(index)"),
          sender: sender,
          content: MessageContent(text: "message \(index)"),
        )
      }
      let path = "/v1/conversation/\(id.rawValue)/messages"

      let tailResponse = try await harness.get(path, query: ["tail": "2"])
      let tailText = try await tailResponse.text()
      #expect(tailResponse.status == .ok, Comment(rawValue: tailText))
      let tail = try JSONValueDecoder().decode(ConversationReadOutput.self, from: try #require(JSONValue.parse(tailText)))
      #expect(tail.messages.map(\.text) == ["message 3", "message 4"])
      #expect(tail.messages.map(\.senderKind) == [.user, .user], "a non-session identity projects as user")

      let poster = try await harness.createSession()
      _ = try await harness.store.post(
        .box(id),
        messageID: MessageID("m5"),
        sender: Sender(id: poster.rawValue, timeZone: TimeZone(identifier: "UTC")!),
        content: MessageContent(text: "from a session"),
      )
      let withSessionResponse = try await harness.get(path, query: ["tail": "1"])
      let withSessionText = try await withSessionResponse.text()
      let withSession = try JSONValueDecoder().decode(ConversationReadOutput.self, from: try #require(JSONValue.parse(withSessionText)))
      #expect(withSession.messages.map(\.senderKind) == [.session], "a kernel-session sender projects as session")

      let cursor = try #require(tail.messages.first).n
      let olderResponse = try await harness.get(path, query: ["tail": "2", "before": "\(cursor)"])
      let olderText = try await olderResponse.text()
      #expect(olderResponse.status == .ok, Comment(rawValue: olderText))
      let older = try JSONValueDecoder().decode(ConversationReadOutput.self, from: try #require(JSONValue.parse(olderText)))
      #expect(older.messages.map(\.text) == ["message 1", "message 2"])

      #expect(try await harness.get(path, query: ["tail": "0"]).status == .badRequest)
      #expect(try await harness.get(path, query: ["tail": "501"]).status == .badRequest)
      #expect(try await harness.get(path, query: ["after": "0"]).status == .ok, "the head-anchored read stays untouched")
    }
  }
}
