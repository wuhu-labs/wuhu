import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Synchronization
import Testing
import WuhuAI

private func targetedCompact(model: String?, effort: String? = nil, preReads: [String] = []) -> ToolCall {
  var arguments: [String: JSONValue] = ["summary": .string("where things stand")]
  if !preReads.isEmpty { arguments["pre_reads"] = .array(preReads.map { .string($0) }) }
  if let model { arguments["model"] = .string(model) }
  if let effort { arguments["effort"] = .string(effort) }
  return .init(id: "call_t", name: "compact", arguments: .object(.init(uniqueKeysWithValues: arguments.sorted { $0.key < $1.key })))
}

private struct TargetRefused: Error, CustomStringConvertible {
  var description: String { "unknownProvider: nope" }
}

@Suite struct CompactTargetTests {
  @Test func effortWithoutModelOrABlankModelIsATypedRefusal() {
    #expect(throws: CompactArgumentsError.effortWithoutModel) { _ = try decodeArguments(CompactArguments.self, from: targetedCompact(model: nil, effort: "low")) }
    #expect(throws: CompactArgumentsError.emptyModel) { _ = try decodeArguments(CompactArguments.self, from: targetedCompact(model: " ")) }
    let decoded = try? decodeArguments(CompactArguments.self, from: targetedCompact(model: "work", effort: "low"))
    #expect(decoded?.target == CompactionTarget(model: "work", effort: "low"))
  }

  @Test func aRefusedTargetFoldsNothingAndTheTurnContinues() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "refused target", kind: .agent, createdBy: "morgan", model: .test)
      let seen = Mutex<[CompactionTarget?]>([])
      let script = InferenceScript([
        Fix.replying("switching", calls: [targetedCompact(model: "nope/x")]),
        { request in
          let result = try #require(request.lines.last)
          #expect(result.role == .toolResult)
          #expect(result.message.toolResult?.isError == true)
          #expect(result.text.contains("compact target \"nope/x\" refused, nothing was folded"))
          #expect(result.text.contains("unknownProvider: nope"))
          return Fix.reply("staying put")
        },
      ])
      var config = makeConfig(inference: { try await script($0) })
      config.prepareCompaction = { _, _, target in
        seen.withLock { $0.append(target) }
        throw TargetRefused()
      }
      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("work"), to: id)
        try await until("refusal is followed by another inference") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(seen.withLock { $0 } == [CompactionTarget(model: "nope/x")])
      #expect(try await sessions.generationState(id).generation == 0)
      #expect(try await sessions.record(id).errorMessage == nil)
      let lines = try await sessions.lines(id)
      #expect(!lines.contains { $0.key == LineKey.head })
      #expect(lines.contains { $0.key.hasPrefix("message:") && $0.role == .user && $0.text.hasSuffix("\n\nwork") })
    }
  }

  @Test func anAcceptedTargetReachesPlacementAndTheCompactionCommits() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "accepted target", kind: .agent, createdBy: "morgan", model: .test)
      let seen = Mutex<[CompactionTarget?]>([])
      let script = InferenceScript([
        Fix.replying("switching", calls: [targetedCompact(model: "work", effort: "low")]),
        Fix.replying("continuing on the target"),
      ])
      var config = makeConfig(inference: { try await script($0) })
      config.prepareCompaction = { _, _, target in
        seen.withLock { $0.append(target) }
        return nil
      }
      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("work"), to: id)
        try await until("compaction then continuation") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(seen.withLock { $0 } == [CompactionTarget(model: "work", effort: "low")])
      #expect(try await sessions.generationState(id).generation == 1)
      let head = try #require(try await sessions.lines(id).first { $0.key == "head:summary" })
      #expect(head.role == .user)
      #expect(head.text == "<conversation-summary>\nwhere things stand\n</conversation-summary>")
    }
  }

  @Test func aMovedGenerationReReadsUnderItsOwnHead() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let old = SessionModelRoute(group: "work", member: "primary", specifier: .test, bindingFingerprint: "fixture", epoch: "primary", reason: .create, placedAt: Date(timeIntervalSince1970: 0), evidence: [])
      let id = try await sessions.createSession(group: .shared, title: "moved", kind: .agent, createdBy: "morgan", executor: .modelGroup(id: "work", effort: "high"), modelRoute: old)
      let script = InferenceScript([
        Fix.replying("switching", calls: [targetedCompact(model: nil, preReads: ["/notes.md"])]),
        { request in
          #expect(request.lines.first { $0.key == LineKey.head }?.text.contains("files to re-read (re-established below): /notes.md") == true)
          let read = try #require(request.lines.first { $0.key == "reestablish" })
          #expect(read.role == .user)
          #expect(read.text.contains("<compaction-reestablished>"))
          #expect(read.text.contains("no file"))
          return Fix.reply("continuing")
        },
      ])
      var config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      config.prepareCompaction = { _, _, _ in
        var next = old
        next.specifier.effort = "low"
        return ModelRouteTransition(expectedEpoch: old.epoch, route: next, binding: .init(identity: "scope", epoch: old.epoch), carriesTail: true)
      }
      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("work"), to: id)
        try await until("the moved generation re-reads and continues") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(try await sessions.generationState(id).generation == 1)
    }
  }
}
