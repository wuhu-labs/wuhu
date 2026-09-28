import ClaudeStream
import Foundation
import GRDB
import JSONValue
import OrderedCollections
import SessionDomain
@testable import SpaceCore
import Testing

// Fixtures are Claude Code 2.1.272's standard output and its own session log from runs on
// a dev Mac's ~/wuhu-probe/runs, with long values shortened alike wherever they occur (the
// manual run's prompt snapshots; every string over 1,000 characters and tool list in
// the automatic runs):
// - manual: 029-rebuild-123331, one `/compact`, with images;
// - automatic: 030-autocompact-133726, one automatic compaction mid-turn. One frame holds
//   a uuid written twice with different bytes, the boundary, and the lines after it;
// - two-automatic-compactions: the first 134 log lines of 025-autocompact-013412, fed one
//   line per frame because that run's standard output was cut at 6,000 bytes a line.
// The carried lines were read off each log; every automatic boundary also names one
// uuid Claude Code never wrote.
@Suite struct ClaudeCodeStorageTests {
  typealias Entry = OrderedDictionary<String, JSONValue>

  private static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().appendingPathComponent("Fixtures/claude-code")

  private static func fixture(_ name: String) throws -> [UInt8] {
    Array(try Data(contentsOf: fixtures.appendingPathComponent(name)))
  }

  private static func mirrorFrames(_ run: String) throws -> [[Entry]] {
    var reader = ClaudeStreamReader()
    return reader.read(try fixture("\(run)-stdout.jsonl")).compactMap { frame in
      if case let .transcriptMirror(entries) = frame { entries } else { nil }
    }
  }

  private static func logLines(_ run: String) throws -> [String] {
    try fixture("\(run)-log.jsonl").split(separator: UInt8(ascii: "\n")).map { String(decoding: $0, as: UTF8.self) }
  }

  private static func rebuiltLines(_ store: SessionStore, _ id: SessionID) async throws -> [String] {
    guard case let .claudeCode(log) = try await store.hydrate(id).transcript else {
      Issue.record("a Claude Code session hydrates its log")
      return []
    }
    return log.entries.map { JSONValue.object($0).jsonString() }
  }

  private static func claudeSession(_ store: SessionStore) async throws -> SessionID {
    try await store.createSession(
      group: .shared,
      title: "claude", kind: .agent, createdBy: "morgan",
      executor: .claudeCode(ModelSpecifier(provider: "claude", model: "opus", effort: "high")),
      snapshot: .init(),
    )
  }

  // After every frame the rebuild is Claude Code's own log from the latest boundary on,
  // preceded by the lines that boundary carries; before any boundary it is the log's prefix.
  private static func replay(_ frames: [[Entry]], log: [String], carried: [Int: [Int]]) async throws {
    let store = try makeSpace().sessions
    let id = try await claudeSession(store)
    #expect(try await rebuiltLines(store, id).isEmpty)
    for boundary in carried.keys {
      #expect(log[boundary].contains(#""subtype":"compact_boundary""#))
    }
    var written = 0
    for entries in frames {
      try await store.appendClaudeCodeMirror(id, entries: entries)
      written += entries.count
      let expected = carried.keys.filter { $0 < written }.max().map { boundary in
        carried[boundary]!.map { log[$0] } + log[boundary ..< written]
      } ?? Array(log[..<written])
      #expect(try await rebuiltLines(store, id) == expected, "after \(written) lines")
    }
    #expect(written == log.count)
    #expect(try await store.generationState(id).generation == carried.count)
  }

  @Test func manualCompactionRebuildsClaudeCodesOwnLog() async throws {
    try await withSessionDeps {
      try await Self.replay(try Self.mirrorFrames("manual"), log: try Self.logLines("manual"), carried: [30: [23]])
    }
  }

  @Test func automaticCompactionRebuildsClaudeCodesOwnLog() async throws {
    try await withSessionDeps {
      try await Self.replay(
        try Self.mirrorFrames("automatic"), log: try Self.logLines("automatic"), carried: [48: [39, 44, 45, 46, 47]],
      )
    }
  }

  @Test func twoAutomaticCompactionsRebuildClaudeCodesOwnLog() async throws {
    try await withSessionDeps {
      let log = try Self.logLines("two-automatic-compactions")
      try await Self.replay(
        try log.map { [try #require(JSONValue.parse($0)?.object)] },
        log: log,
        carried: [48: [39, 44, 45, 46, 47], 89: [80, 85, 86, 87, 88]],
      )
    }
  }

  @Test func claudeSessionIDIsMintedOnceAtCreation() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      guard case let .claudeCode(first) = try await store.hydrate(id).transcript,
            case let .claudeCode(second) = try await store.hydrate(id).transcript
      else {
        Issue.record("a Claude Code session hydrates its log")
        return
      }
      #expect(first.sessionID == second.sessionID)
      #expect(first.entries.isEmpty)
    }
  }

  @Test func imagesAreStoredAsBlobsAndRestoredExactly() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let id = try await Self.claudeSession(space.sessions)
      let frames = try Self.mirrorFrames("manual")
      try await space.sessions.appendClaudeCodeMirror(id, entries: frames[0])
      let log = try Self.logLines("manual")
      let images = log.flatMap { line in
        line.split(separator: "\"").filter { $0.hasPrefix("iVBORw0KGgo") }.map(String.init)
      }
      #expect(Set(images).count == 3)
      let payloads = try await space.writer.read { db in
        try String.fetchAll(db, sql: "SELECT payload FROM session_contents WHERE session_id = ?", arguments: [id.rawValue])
      }
      for image in Set(images) {
        #expect(!payloads.contains { $0.contains(image) })
        let reference = "wuhu-blob:" + Substrate.blobHash(Array(try #require(Data(base64Encoded: image))))
        #expect(payloads.contains { $0.contains(reference) })
      }
      #expect(try await Self.rebuiltLines(space.sessions, id) == Array(log[..<frames[0].count]))
    }
  }

  @Test func nonCanonicalBase64StaysInlineAndReadsFileIsRestored() async throws {
    try await withSessionDeps {
      let space = try makeSpace()
      let id = try await Self.claudeSession(space.sessions)
      let canonical = Data([0, 1, 2, 250]).base64EncodedString()
      let entries: [Entry] = [
        ["type": "user", "uuid": "u1", "message": ["content": [
          ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": "AAEC+g"]],
          ["type": "tool_result", "content": [["type": "image", "source": ["type": "url", "data": .string(canonical)]]]],
        ]], "toolUseResult": ["type": "image", "file": ["base64": .string(canonical), "type": "image/png"]]],
      ]
      try await space.sessions.appendClaudeCodeMirror(id, entries: entries)
      let payload = try await space.writer.read { db in
        try String.fetchOne(db, sql: "SELECT payload FROM session_contents WHERE session_id = ? AND id = 'u1'", arguments: [id.rawValue])
      }
      #expect(payload?.contains("\"AAEC+g\"") == true)
      #expect(payload?.contains("\"file\":{\"base64\":\"wuhu-blob:") == true)
      #expect(payload?.components(separatedBy: canonical).count == 2)
      guard case let .claudeCode(log) = try await space.sessions.hydrate(id).transcript else {
        Issue.record("a Claude Code session hydrates its log")
        return
      }
      #expect(log.entries == entries)
    }
  }

  @Test func aFrameIsWrittenWholeOrNotAtAll() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let id = try await Self.claudeSession(store)
      try await store.appendClaudeCodeMirror(id, entries: [["type": "user", "uuid": "a"]])
      await #expect(throws: ClaudeCodeStoreError.self) {
        try await store.appendClaudeCodeMirror(id, entries: [
          ["type": "user", "uuid": "c"],
          ["type": "system", "subtype": "compact_boundary", "uuid": "b"],
        ])
      }
      await #expect(throws: ClaudeCodeStoreError.self) {
        try await store.appendClaudeCodeMirror(id, entries: [
          ["type": "user", "uuid": "c"],
          ["type": "system", "subtype": "compact_boundary", "uuid": "b", "compactMetadata": ["preservedMessages": ["allUuids": [1]]]],
        ])
      }
      #expect(try await Self.rebuiltLines(store, id) == [#"{"type":"user","uuid":"a"}"#])
      #expect(try await store.generationState(id).generation == 0)

      try await store.appendClaudeCodeMirror(id, entries: [
        ["type": "user", "uuid": "c"],
        ["type": "user", "uuid": "a", "slug": "s"],
        ["type": "user", "uuid": "c"],
        ["type": "system", "subtype": "compact_boundary", "uuid": "b", "compactMetadata": [
          "trigger": "auto", "preservedMessages": ["allUuids": ["a", "never-written"]],
        ]],
        ["type": "last-prompt"],
        ["type": "last-prompt"],
      ])
      #expect(try await Self.rebuiltLines(store, id) == [
        #"{"type":"user","uuid":"a"}"#,
        #"{"type":"user","uuid":"a","slug":"s"}"#,
        #"{"type":"system","subtype":"compact_boundary","uuid":"b","compactMetadata":{"trigger":"auto","preservedMessages":{"allUuids":["a","never-written"]}}}"#,
        #"{"type":"last-prompt"}"#,
        #"{"type":"last-prompt"}"#,
      ])
    }
  }

  @Test func onlyClaudeCodeSessionsTakeMirrorFrames() async throws {
    try await withSessionDeps {
      let store = try makeSpace().sessions
      let kernel = try await store.createSession(group: .shared, title: "k", kind: .agent, createdBy: "morgan", model: .test)
      await #expect(throws: ClaudeCodeStoreError.notAClaudeCodeSession(kernel.rawValue)) {
        try await store.appendClaudeCodeMirror(kernel, entries: [["type": "user", "uuid": "a"]])
      }
      let claude = try await Self.claudeSession(store)
      #expect(try await store.transcript(claude) == Transcript())
      #expect(try await store.transcriptSnapshot(claude).items.isEmpty)
    }
  }
}
