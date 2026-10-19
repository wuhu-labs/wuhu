import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Synchronization
import Testing
import WuhuAI

private func targetedCompact(model: String?, effort: String? = nil) -> ToolCall {
  var arguments: [String: JSONValue] = ["summary": .string("where things stand")]
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
          guard case let .toolResult(result)? = request.transcript.items.last,
                case let .failure(failure) = result.payload else { throw UnexpectedCall("missing target refusal") }
          #expect(failure.message.contains("compact target \"nope/x\" refused, nothing was folded"))
          #expect(failure.message.contains("unknownProvider: nope"))
          return Fix.reply("staying put")
        },
      ])
      var config = makeConfig(inference: { try await script($0) })
      config.prepareCompaction = { _, _, target in
        seen.withLock { $0.append(target) }
        throw TargetRefused()
      }
      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("work"), to: id)
        try await until("refusal is followed by another inference") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(seen.withLock { $0 } == [CompactionTarget(model: "nope/x")])
      #expect(try await sessions.generationState(id).generation == 0)
      #expect(try await sessions.record(id).errorMessage == nil)
      let transcript = try await sessions.hydrate(id).transcript.kernel
      #expect(!transcript.items.contains { if case .generationHead = $0 { true } else { false } })
      #expect(transcript.items.contains { if case let .message(message) = $0 { message.content.text == "work" } else { false } })
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
        _ = try await service.enqueue(item: Fix.message("work"), to: id)
        try await until("compaction then continuation") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(seen.withLock { $0 } == [CompactionTarget(model: "work", effort: "low")])
      #expect(try await sessions.generationState(id).generation == 1)
      guard case let .generationHead(head)? = try await sessions.hydrate(id).transcript.kernel.items.first else {
        Issue.record("expected a generation head")
        return
      }
      #expect(head.summary == "where things stand")
    }
  }
}
