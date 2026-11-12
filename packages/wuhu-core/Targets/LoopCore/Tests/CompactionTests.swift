import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
@testable import LoopCore
import SessionDomain
import SessionTools
import SpaceCore
import Testing
import WuhuAI

private let tightBudget = ContextBudget(maxInput: 1100, maxOutput: 100)

private func compactCall(
  summary: String,
  preReads: [String] = [],
  bookmark: String? = nil,
) -> ToolCall {
  var arguments: [String: JSONValue] = ["summary": .string(summary)]
  if !preReads.isEmpty { arguments["pre_reads"] = .array(preReads.map(JSONValue.string)) }
  if let bookmark { arguments["bookmark"] = .string(bookmark) }
  return .init(id: "call_c", name: "compact", arguments: .object(.init(uniqueKeysWithValues: arguments.sorted { $0.key < $1.key })))
}

@Suite struct CompactionTests {
  @Test(arguments: ["", " \n "], [false, true])
  func emptySummaryIsATypedRefusalAndTheTurnContinues(summary: String, preRead: Bool) async throws {
    let call = compactCall(summary: summary, preReads: preRead ? ["/notes.md"] : [])
    #expect(throws: CompactArgumentsError.emptySummary) { _ = try decodeArguments(CompactArguments.self, from: call) }
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "compact misuse", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("compact", calls: [call]),
        { request in
          let result = try #require(request.lines.last)
          #expect(result.role == .toolResult)
          #expect(result.message.toolResult?.isError == true)
          #expect(result.text.contains("emptySummary"))
          #expect(result.text.contains("non-empty summary"))
          return Fix.reply("continued after refusal")
        },
      ])
      try await runService(space, makeConfig(inference: { try await script($0) })) { service in
        try await service.enqueue(item: Fix.message("work"), to: id)
        try await until("compact refusal is followed by another inference") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(try await sessions.generationState(id).generation == 0)
      #expect(try await sessions.record(id).errorMessage == nil)
    }
  }

  @Test(arguments: [false, true])
  func aBookmarkInTheCompactReplyIsRefusedBeforeFoldingOrParking(park: Bool) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let id = try await space.sessions.createSession(group: .shared, title: "same-reply bookmark", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("bookmark then compact", calls: [
          .init(id: "bookmark", name: "bookmark", arguments: .object(["name": .string("cut")])),
          .init(id: "compact", name: "compact", arguments: .object(["summary": .string("folded"), "bookmark": .string("cut"), "park": .bool(park)])),
        ]),
        { request in
          let receipt = try #require(request.lines.last)
          #expect(receipt.role == .toolResult)
          #expect(receipt.message.toolResult?.isError == true)
          #expect(receipt.text.contains("bookmark \"cut\""))
          return Fix.reply("continued after refusal")
        },
      ])
      let preparations = Box(0)
      var config = makeConfig(inference: { try await script($0) })
      config.prepareCompaction = { _, _, _ in preparations.withLock { $0 += 1 }; return nil }
      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("work"), to: id)
        try await until("the compact refusal is written") {
          let errored = try await space.sessions.record(id).work == .errored
          return try await space.sessions.lines(id).contains { line in
            guard case let .toolResult(receipt) = line.message, line.text.contains("bookmark") else { return false }
            return receipt.isError
          } || errored || space.worker.cell(SessionCell.ID(id.rawValue)).turn()?.turn.isFolding == true
        }
        #expect(try await space.sessions.record(id).errorMessage == nil)
        #expect(space.worker.cell(SessionCell.ID(id.rawValue)).turn()?.turn.isFolding == false)
        try await until("a normal model turn follows the refusal") { try await space.sessions.settledWork(id) && script.count == 2 }
        #expect(try await space.sessions.generation(id) == 0)
        #expect(preparations.value == 0)
      }
    }
  }

  @Test func `a model that stops past the hard threshold starts its next generation from a pointer`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.replying("big turn", tokens: 900), Fix.replying("fresh start", tokens: 100)])
      try await runService(space, makeConfig(inference: { try await script($0) }, budget: tightBudget)) { service in
        try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("fresh turn landed") { try await sessions.settledWork(sid) && script.count == 2 }
      }
      let lines = try await sessions.lines(sid)
      #expect(try await sessions.generationState(sid).generation == 1)
      let summary = try #require(lines.first { $0.key == "head:summary" })
      #expect(summary.role == .user)
      #expect(summary.text == "<conversation-summary>\n" + SessionPrompt.pointerSummary(session: sid, generation: 0) + "\n</conversation-summary>")
      #expect(summary.text.contains("/_/session-transcripts/\(sid.rawValue)/0.outline.txt"))
      #expect(lines.assistantLines.map(\.text) == ["fresh start"])
      #expect(lines.assistantLines.allSatisfy { $0.meta != nil })
      #expect(!lines.contains { $0.key.hasPrefix("message:") || $0.role == .toolResult })
    }
  }

  @Test func aGenerationWithNothingToDropThatStillDoesNotFitErrors() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([Fix.replying("big turn", tokens: 900), Fix.replying("the prompt alone is as big", tokens: 900)])
      try await runService(space, makeConfig(inference: { try await script($0) }, budget: tightBudget)) { service in
        try await service.enqueue(item: Fix.message("hello"), to: sid)
        try await until("errored") { try await sessions.record(sid).work == .errored }
      }
      #expect(script.count == 2)
      #expect(try await sessions.generationState(sid).generation == 1, "one pointer dropped the turn; a second would drop nothing")
      #expect(try await sessions.record(sid).errorMessage?.contains("nothing left to drop") == true)
    }
  }

  @Test func `contextLengthExceeded escalates to compaction instead of backoff`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.failing(.contextTooLong),
        Fix.replying("fits now"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("hello"), to: sid)
        // The clock never advances: any backoff would hang this convergence.
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      #expect(try await sessions.generationState(sid).generation == 1)
      let summary = try #require(try await sessions.lines(sid).first { $0.key == "head:summary" })
      #expect(summary.text == "<conversation-summary>\n" + SessionPrompt.pointerSummary(session: sid, generation: 0) + "\n</conversation-summary>")
      #expect(script.count == 2)
    }
  }

  @Test func `bookmark and compact are kernel tools and rewind to the bookmark`() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let sid = try await sessions.createSession(group: .shared, title: "t", kind: .agent, createdBy: "morgan", model: .test)

      let script = InferenceScript([
        Fix.replying("marking", calls: [.init(id: "call_0", name: "bookmark", arguments: .object(["name": .string("b1")]))]),
        Fix.replying("explored a dead end"),
        Fix.replying("folding", calls: [compactCall(summary: "exploration notes", bookmark: "b1")]),
        Fix.replying("continuing"),
      ])
      let config = makeConfig(inference: { try await script($0) })

      try await runService(space, config) { service in
        try await service.enqueue(item: Fix.message("explore"), to: sid)
        try await until("explored") {
          guard script.count >= 2 else { return false }
          return try await sessions.settledWork(sid)
        }
        try await service.enqueue(item: Fix.message("now compact"), to: sid)
        try await until("settled") { try await sessions.settledWork(sid) }
      }

      let lines = try await sessions.lines(sid)
      #expect(lines.first { $0.key == "head:summary" }?.text == "<conversation-summary>\nexploration notes\n</conversation-summary>")
      let replies = lines.assistantLines
      #expect(replies.map(\.text) == ["explored a dead end", "continuing"])
      #expect(replies.first?.meta == nil, "a carried reply has no inference metadata in this generation")
      #expect(replies.last?.meta != nil)
      let messages = lines.filter { $0.key.hasPrefix("message:") }
      #expect(messages.count == 1)
      #expect(messages.first?.role == .user)
      #expect(messages.first?.text.hasSuffix("\n\nnow compact") == true)
      #expect(!lines.contains { $0.role == .toolResult }, "the bookmark and compact receipts belong to the old generation")
    }
  }
}
