import DeterministicDependencies
import Foundation
import GRDB
import JSONValue
import SessionDomain
import struct SpaceContract.PromptSession
@testable import SpaceCore
import SpaceFS
import Testing
import WuhuAI

// A generation's lines are the messages its requests send, written beside the
// typed items and never rewritten.
@Suite(.deterministicDependencies) struct SessionLinesTests {
  private static let tools = [Tool(name: "read", description: "read a file", parameters: .object(["type": "object"]))]

  private func created(_ space: Space) async throws -> SessionID {
    try await space.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test, snapshot: .init())
  }

  @discardableResult private func storePrompt(_ store: SessionStore, _ id: SessionID, _ prompt: String = "the prompt") async throws -> String {
    guard case let .pending(pending) = try await store.activatePrompt(id) else { throw LinesUnexpected() }
    let opening = pending.opening ? PromptOpening(group: "the group's", session: "the session's") : nil
    return try await store.storePrompt(id, for: pending, prompt, opening: opening, tools: Self.tools, session: PromptSession(try await store.record(id))).rendered
  }

  private func keys(_ store: SessionStore, _ id: SessionID, generation: Int = 0) async throws -> [String] {
    try await store.lines(id, generation: generation).map(\.key)
  }

  private func direct(_ text: String) -> TranscriptItem {
    .direct(.init(id: UUID(), sender: SessionFix.sender, timestamp: fixedDate, content: .init(text: text)))
  }

  private func message(_ id: String) -> TranscriptItem {
    .message(.init(id: UUID(), messageID: .init(id), conversationID: .init("ch1"), sender: SessionFix.sender, timestamp: fixedDate, content: .init(text: "message \(id)")))
  }

  private static let notice = TranscriptItem.notification(.init(id: UUID(), timestamp: fixedDate, kind: .context, subscriptionID: .init("context"), content: .init(text: "context notice")))

  private func clean(_ store: SessionStore, _ id: SessionID, rendered: String? = nil) async throws -> Bool {
    let generation = try await store.lineGenerations(id).current
    guard case let .rendered(stored) = try await store.activatePrompt(id) else { throw LinesUnexpected() }
    return try await store.lineDifference(id, generation: generation, rendered: rendered ?? stored.rendered, transcript: store.transcript(id)) == nil
  }

  @Test func linesFollowTheRenderAndNeverChange() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await created(space)
      #expect(try await store.lines(id, generation: 0).map(\.position) == [3], "positions 1 and 2 wait for the prompt's opening")
      try await storePrompt(store, id)
      #expect(try await keys(store, id) == ["system", "group", "session", "head"])

      var seen = try await store.lines(id, generation: 0)
      func step(_ write: () async throws -> Void, adds expected: [String]) async throws {
        try await write()
        let now = try await store.lines(id, generation: 0)
        #expect(Array(now.prefix(seen.count)) == seen, "a written line never changes")
        #expect(now.dropFirst(seen.count).map(\.key) == expected)
        #expect(now.map(\.position) == Array(0 ..< now.count))
        #expect(try await clean(store, id))
        seen = now
      }

      let hello = direct("hello")
      guard case let .direct(sent) = hello else { throw LinesUnexpected() }
      try await step({ try await store.append(id, items: [hello], inputOrigin: true) }, adds: ["direct:\(sent.id.uuidString.lowercased())"])
      let attempt = UUID()
      let calls = ["a", "b"].map { ToolCall(id: $0, name: "read", arguments: .object([:])) }
      try await step({
        try await store.appendAssistant(id, attemptID: attempt, message: SessionFix.assistant("reading", toolCalls: calls), metadata: SessionFix.metadata)
      }, adds: ["attempt:\(attempt.uuidString.lowercased())"])
      try await step({ try await store.writeToolResult(id, SessionFix.toolResult(callID: "a")) }, adds: ["call:a"])
      try await step({ try await store.append(id, items: [Self.notice], inputOrigin: nil) }, adds: [])
      try await step({ try await store.writeToolResult(id, SessionFix.toolResult(callID: "b")) }, adds: ["call:b"])
      try await step({ try await store.append(id, items: [message("m1")], inputOrigin: true) }, adds: ["subscription:context", "message:m1"])

      let assistant = try #require(seen.first { $0.key.hasPrefix("attempt:") })
      #expect(assistant.role == .assistant)
      let meta = try JSONDecoder().decode(TranscriptLine.Meta.self, from: Data(try #require(assistant.meta).utf8))
      #expect(meta == .init(stopReason: .stop, usage: try #require(SessionFix.metadata.usage)))
      let rendered = try #require(try JSONDecoder().decode([String: String].self, from: Data(seen[0].message.utf8))["rendered"])
      let file = try await space.renderedFiles(in: .shared).read(RenderedFiles.path(rendered)).1
      #expect(try JSONDecoder().decode(TranscriptPreamble.self, from: file) == .init(system: "the prompt", tools: Self.tools))
    }
  }

  @Test func aCompactionOpensLinesForTheNewGenerationAndKeepsTheOld() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await created(space)
      try await storePrompt(store, id)
      try await store.append(id, items: [direct("first"), message("m1")], inputOrigin: true)
      let closed = try await store.lines(id, generation: 0)

      let head = GenerationHead(id: UUID(), timestamp: fixedDate, summary: "compacted", snapshot: .init(), runningWork: [])
      _ = try await store.writeCompaction(id, head: head, kept: 2 ..< 3)
      #expect(try await store.lines(id, generation: 0) == closed)
      #expect(try await keys(store, id, generation: 1) == ["head", "head:summary", "head:nudge", "message:m1"])
      try await storePrompt(store, id, "the next prompt")
      try await store.append(id, items: [message("m2")], inputOrigin: true)
      #expect(try await keys(store, id, generation: 1) == ["system", "group", "session", "head", "head:summary", "head:nudge", "message:m1", "message:m2"])
      #expect(try await clean(store, id))
      let generations = try await store.lineGenerations(id)
      #expect(generations.current == 1 && generations.withLines == [0, 1])
    }
  }

  @Test func aGenerationThatOpenedWithoutLinesGetsNone() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await created(space)
      // A generation that predates the table.
      try await space.writer.write { db in
        try db.execute(sql: #"DELETE FROM "session_lines" WHERE session_id = ?"#, arguments: [id.rawValue])
      }
      try await storePrompt(store, id)
      try await store.append(id, items: [direct("hello")], inputOrigin: true)
      #expect(try await store.lines(id, generation: 0).isEmpty)
      #expect(try await clean(store, id), "nothing to compare")
      #expect(try await store.lineGenerations(id).withLines.isEmpty)
    }
  }

  @Test func theOpeningIsStoredAsLinesOneAndTwoAndReadBack() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let session = PromptSession(try await store.record(try await created(space)))

      let both = try await created(space)
      guard case let .pending(pending) = try await store.activatePrompt(both) else { throw LinesUnexpected() }
      #expect(pending.opening)
      let stored = try await store.storePrompt(both, for: pending, "system", opening: .init(group: "group text", session: "session text"), tools: [], session: session)
      #expect(stored.opening == ["group text", "session text"])
      #expect(try await store.activatePrompt(both) == .rendered(stored))
      let lines = try await store.lines(both, generation: 0)
      #expect(lines.map(\.position) == [0, 1, 2, 3] && lines.map(\.role) == [.system, .user, .user, .user])

      let groupless = try await created(space)
      guard case let .pending(next) = try await store.activatePrompt(groupless) else { throw LinesUnexpected() }
      let alone = try await store.storePrompt(groupless, for: next, "system", opening: .init(group: "", session: "session text"), tools: [], session: session)
      #expect(alone.opening == ["session text"])
      #expect(try await store.activatePrompt(groupless) == .rendered(alone))
      #expect(try await store.lines(groupless, generation: 0).map(\.position) == [0, 2, 3], "a group without instructions has no line 1")
      try await store.append(groupless, items: [direct("hello")], inputOrigin: true)
      #expect(try await clean(store, groupless))

      // A generation opened before the opening had positions: its transcript starts at 1.
      let older = try await created(space)
      try await space.writer.write { db in
        try db.execute(sql: #"UPDATE "session_lines" SET position = 1 WHERE session_id = ?"#, arguments: [older.rawValue])
      }
      guard case let .pending(whole) = try await store.activatePrompt(older) else { throw LinesUnexpected() }
      #expect(!whole.opening)
      #expect(try await store.storePrompt(older, for: whole, "everything", tools: [], session: session).opening.isEmpty)
      try await store.append(older, items: [direct("hello")], inputOrigin: true)
      #expect(try await store.lines(older, generation: 0).map(\.position) == [0, 1, 2])
      #expect(try await clean(store, older))
    }
  }

  @Test func aDifferenceNamesTheFirstPositionThatDisagrees() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await created(space)
      let rendered = try await storePrompt(store, id)
      try await store.append(id, items: [direct("one"), direct("two")], inputOrigin: true)
      #expect(try await clean(store, id))
      #expect(try await !clean(store, id, rendered: "another"))

      try await space.writer.write { db in
        try db.execute(sql: #"UPDATE "session_lines" SET message = '{}' WHERE session_id = ? AND position = 5"#, arguments: [id.rawValue])
      }
      let changed = try #require(try await store.lineDifference(id, generation: 0, rendered: rendered, transcript: store.transcript(id)))
      #expect(changed.position == 5)
      #expect(changed.line != nil && changed.render != nil && changed.line != changed.render)

      try await space.writer.write { db in
        try db.execute(sql: #"DELETE FROM "session_lines" WHERE session_id = ? AND position >= 4"#, arguments: [id.rawValue])
      }
      let missing = try #require(try await store.lineDifference(id, generation: 0, rendered: rendered, transcript: store.transcript(id)))
      #expect(missing.position == 4 && missing.line == nil && missing.render != nil)
    }
  }

  @Test func theTranscriptFilesRenderTheLines() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let store = space.sessions
      let id = try await created(space)
      let rendered = try await storePrompt(store, id)
      try await store.append(id, items: [direct("hello\nthere")], inputOrigin: true)
      try await store.appendAssistant(id, attemptID: UUID(), message: SessionFix.assistant("hi"), metadata: SessionFix.metadata)
      let files = space.sessionTranscripts(in: .shared)
      let folder = "/_/session-transcripts/\(id.rawValue)"
      #expect(try await files.list(folder).1.map(\.name) == ["current.jsonl", "current.outline.txt", "0.jsonl", "0.outline.txt"])

      let jsonl = String(decoding: try await files.read(folder + "/current.jsonl").1, as: UTF8.self)
      #expect(try await files.read(folder + "/0.jsonl").1 == Data(jsonl.utf8))
      let records = try jsonl.split(separator: "\n").map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
      #expect(records.map { $0.object?["position"]?.intValue } == [0, 1, 2, 3, 4, 5])
      #expect(records.map { $0.object?["role"]?.stringValue } == ["system", "user", "user", "user", "user", "assistant"])
      #expect(records.map { $0.object?["meta"] != nil } == [false, false, false, false, false, true], "meta beside key, only where the line has one")
      #expect(records[5].object?["meta"]?.object?["stop_reason"]?.stringValue == "stop")

      let outline = String(decoding: try await files.read(folder + "/current.outline.txt").1, as: UTF8.self).split(separator: "\n")
      #expect(outline.count == 6)
      #expect(outline[0].hasPrefix("0 ") && outline[0].hasSuffix("system system /_/rendered/\(rendered)"))
      #expect(outline[1].hasSuffix(" user group the group's") && outline[2].hasSuffix(" user session the session's"))
      #expect(outline[4].contains(" user direct:") && outline[4].contains("hello there"))

      for path in [folder + "/1.jsonl", folder + "/current.md", "/_/session-transcripts/nobody/current.jsonl"] {
        await #expect(throws: SpaceError.notFound(path)) { try await files.read(path) }
      }
      await #expect(throws: SpaceError.notFound(folder)) { try await space.sessionTranscripts(in: .settings).list(folder) }
      await #expect(throws: SpaceError.sentViewReadOnly(folder + "/current.jsonl")) {
        try await files.write(folder + "/current.jsonl", Data(), ifMatch: nil)
      }
      await #expect(throws: SpaceError.sentViewReadOnly(folder + "/x.md")) {
        try await space.refuseWrite(SpacePath(validating: folder + "/x.md"), in: .shared, by: .anonymous, acting: .shared)
      }

      let sent = RenderedFiles.path(rendered)
      #expect(records[0].object?["message"] == ["rendered": .string(rendered)])
      #expect(try await space.renderedFiles(in: .shared).stat(sent).size > 0)
      await #expect(throws: SpaceError.notFound(sent)) { try await space.renderedFiles(in: .settings).read(sent) }
      await #expect(throws: SpaceError.notFound("/_/rendered/0000")) { try await space.renderedFiles(in: .shared).read("/_/rendered/0000") }
      await #expect(throws: SpaceError.sentViewReadOnly(sent)) {
        try await space.refuseWrite(SpacePath(validating: sent), in: .shared, by: .anonymous, acting: .shared)
      }
    }
  }
}

private struct LinesUnexpected: Error {}
