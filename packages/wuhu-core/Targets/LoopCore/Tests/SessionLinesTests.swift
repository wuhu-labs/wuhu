import DeterministicDependencies
import Foundation
import GRDB
import JSONValue
@testable import LoopCore
import SessionDomain
import struct SpaceContract.PromptSession
@testable import SpaceCore
import SpaceFS
import Testing
import WuhuAI

@Suite(.deterministicDependencies) struct SessionLinesTests {
  private static let tools = [Tool(name: "read", description: "read a file", parameters: .object(["type": "object"]))]

  private func created(_ space: Space) async throws -> SessionID {
    try await space.sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test, snapshot: .init())
  }

  @discardableResult private func storePrompt(_ store: SessionStore, _ id: SessionID, _ prompt: String = "the prompt") async throws -> String {
    guard case let .pending(pending) = try await store.promptForInference(id) else { throw LinesUnexpected() }
    let opening = pending.opening ? PromptOpening(group: "the group's", session: "the session's") : nil
    let stored = try await store.storeInferencePrompt(id, for: pending, prompt, opening: opening, tools: Self.tools, session: PromptSession(try await store.record(id)))
    await store.noMail(id)
    return stored.rendered
  }

  @Test func theOpeningIsStoredAsLinesOneAndTwoAndReadBack() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let store = space.sessions
      let session = PromptSession(try await store.record(try await created(space)))

      let both = try await created(space)
      guard case let .pending(pending) = try await store.promptForInference(both) else { throw LinesUnexpected() }
      #expect(pending.opening)
      let stored = try await store.storeInferencePrompt(both, for: pending, "system", opening: .init(group: "group text", session: "session text"), tools: [], session: session)
      await store.noMail(both)
      #expect(stored.opening == ["group text", "session text"])
      #expect(try await store.promptForInference(both) == .rendered(stored))
      let lines = try await store.lines(both, generation: 0)
      #expect(lines.map(\.position) == [0, 1, 2, 3] && lines.map(\.role) == [.system, .user, .user, .user])

      let groupless = try await created(space)
      guard case let .pending(next) = try await store.promptForInference(groupless) else { throw LinesUnexpected() }
      let alone = try await store.storeInferencePrompt(groupless, for: next, "system", opening: .init(group: "", session: "session text"), tools: [], session: session)
      await store.noMail(groupless)
      #expect(alone.opening == ["session text"])
      #expect(try await store.promptForInference(groupless) == .rendered(alone))
      #expect(try await store.lines(groupless, generation: 0).map(\.position) == [0, 2, 3], "a group without instructions has no line 1")

      // A generation opened before the opening had positions: its transcript starts at 1.
      let older = try await created(space)
      try await space.plantHandlerRows(#"UPDATE "session_lines" SET position = 1 WHERE session_id = ?"#, arguments: [older.rawValue])
      guard case let .pending(whole) = try await store.promptForInference(older) else { throw LinesUnexpected() }
      #expect(!whole.opening)
      #expect(try await store.storeInferencePrompt(older, for: whole, "everything", tools: [], session: session).opening.isEmpty)
      await store.noMail(older)
      #expect(try await store.lines(older, generation: 0).map(\.position) == [0, 1])
    }
  }

  @Test func theTranscriptFilesRenderTheLines() async throws {
    try await withSessionHandlerDeps {
      let space = try makeHandlerSpace()
      let store = space.sessions
      let id = try await created(space)
      let rendered = try await storePrompt(store, id)
      _ = try await space.worker.call(SessionCell.ID(id.rawValue)) { cell in
        let rows = cell.rows
        try rows.append(id, lines: [
          TranscriptLine(at: handlerDate, key: "direct:hello", message: .user(.init(content: [.text("hello\nthere")]))),
          TranscriptLine(at: handlerDate, key: "attempt:hello", message: .assistant(.init(content: [.text("hi")])), meta: .init(stopReason: .stop, usage: .init(inputTokens: 5, outputTokens: 5, totalTokens: 100))),
        ])
      }
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
