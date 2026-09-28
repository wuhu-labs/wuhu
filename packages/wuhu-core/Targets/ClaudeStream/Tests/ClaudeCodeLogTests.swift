@testable import ClaudeStream
import Foundation
import JSONValue
import OrderedCollections
import Scratch
import Testing

@Suite struct ClaudeCodeLogTests {
  private static let long = "/tmp/" + String(repeating: "wuhu-activation-", count: 14) + "work"

  // Expected names computed by running Claude Code's JavaScript encoding under Deno.
  @Test(arguments: [
    ("/Users/dev/wuhu-probe/runs/029-rebuild-123331/orig/work", "-Users-dev-wuhu-probe-runs-029-rebuild-123331-orig-work"),
    (long, "-tmp" + String(repeating: "-wuhu-activation", count: 12) + "-wuh-bvmele"),
    (long + "/caf\u{e9}", "-tmp" + String(repeating: "-wuhu-activation", count: 12) + "-wuh-7b8pv6"),
    ("/tmp/caf\u{e9}/\u{1F600} x", "-tmp-caf-----x"),
  ])
  func projectFolderNameMatchesClaudeCode(_ workingFolder: String, _ expected: String) {
    #expect(ClaudeCodeLog.projectFolderName(workingFolder: workingFolder) == expected)
  }

  #if canImport(Darwin)
    @Test func projectFolderNameComposesFirstOnDarwin() {
      #expect(ClaudeCodeLog.projectFolderName(workingFolder: "/tmp/cafe\u{301}/\u{1F600} x") == "-tmp-caf-----x")
    }
  #endif

  @Test func writesOneLinePerEntryUnderTheResolvedWorkingFolder() async throws {
    let root = try scratchURL("claude-log")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    let real = root.appendingPathComponent("real-work")
    let link = root.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    let sessionID = try #require(UUID(uuidString: "E3976B8A-386D-4B77-A3BE-C529268C5F48"))
    let log = ClaudeCodeLog(sessionID: sessionID, entries: [
      ["type": "user", "uuid": "a", "message": ["content": "caf\u{e9} \u{1F600}"]],
      ["type": "queue-operation", "n": 1.5],
    ])
    let path = try await log.write(configDirectory: config.path, workingFolder: link.path)

    let resolved = try #require(realpath(real.path, nil).map { pointer in
      defer { free(pointer) }
      return String(cString: pointer)
    })
    #expect(path == "\(config.path)/projects/\(ClaudeCodeLog.projectFolderName(workingFolder: resolved))/e3976b8a-386d-4b77-a3be-c529268c5f48.jsonl")
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("""
    {"type":"user","uuid":"a","message":{"content":"caf\u{e9} \u{1F600}"}}
    {"type":"queue-operation","n":1.5}

    """.utf8))
    await #expect(throws: (any Error).self) {
      try await log.write(configDirectory: config.path, workingFolder: link.path)
    }
  }

  // The probe's reversed-order delivery session on 2.1.280 (two parallel Reads
  // whose results were logged in reverse), its mirror entries up to the fourth
  // prompt, with the scratch folder rewritten to /tmp/probe. Resumed as is,
  // Claude Code drops every turn after the Reads.
  @Test func rebuildLeavesOutLastPromptEntriesAndNothingElse() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appendingPathComponent("Fixtures/reversed-parallel-reads.jsonl")
    let lines = try String(contentsOf: fixture, encoding: .utf8).split(separator: "\n").map(String.init)
    let entries = try lines.map { try #require(JSONValue.parse($0)?.object) }
    #expect(entries.contains { $0["type"] == .string("last-prompt") })

    let root = try scratchURL("claude-log")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    let work = root.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let log = ClaudeCodeLog(sessionID: UUID(), entries: entries)
    let path = try await log.write(configDirectory: config.path, workingFolder: work.path)

    let kept = zip(lines, entries).filter { $0.1["type"] != .string("last-prompt") }.map(\.0)
    #expect(kept.count == lines.count - 1)
    #expect(try String(contentsOfFile: path, encoding: .utf8) == kept.map { $0 + "\n" }.joined())
  }
}
