import Dependencies
import Foundation
import JSONValue
@testable import LoopCore
import SessionDomain
import SpaceCore
import Synchronization
import Testing
import WuhuAI

private let summary = "where things stand"

private func parkingCompact(model: String? = nil, bookmark: String? = nil) -> ToolCall {
  var arguments: [String: JSONValue] = ["summary": .string(summary), "park": .bool(true), "pre_reads": .array([.string("/notes.md")])]
  if let model { arguments["model"] = .string(model) }
  if let bookmark { arguments["bookmark"] = .string(bookmark) }
  return .init(id: "call_park", name: "compact", arguments: .object(.init(uniqueKeysWithValues: arguments.sorted { $0.key < $1.key })))
}

private func parks(_ text: String = "nothing more is coming") -> InferenceScript.Step {
  Fix.replying(text, calls: [parkingCompact()])
}

private extension Transcript {
  var head: GenerationHead? {
    guard case let .generationHead(head)? = items.first else { return nil }
    return head
  }

  func carries(message text: String) -> Bool {
    items.contains { if case let .message(message) = $0 { message.content.text == text } else { false } }
  }
}

@Suite struct ParkedCompactionTests {
  @Test func parkWithAModelIsATypedRefusal() {
    #expect(throws: CompactArgumentsError.parkWithModel) { _ = try decodeArguments(CompactArguments.self, from: parkingCompact(model: "work")) }
  }

  @Test func aParkedCompactionRunsNothingUntilAWakeStartsItsGeneration() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "parks", kind: .agent, createdBy: "morgan", model: .test)
      let created = try await sessions.promptRevision(id)
      let placements = Mutex(0)
      let script = InferenceScript([
        parks(),
        { request in
          #expect(request.transcript.head?.summary == summary)
          #expect(request.transcript.head?.snapshot.preReads == ["/notes.md"])
          #expect(request.transcript.carries(message: "next"))
          return Fix.reply("on it")
        },
      ])
      var config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      config.prepareCompaction = { _, _, _ in
        placements.withLock { $0 += 1 }
        return nil
      }
      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("wrap up"), to: id)
        try await until("the park settles") { try await sessions.settledWork(id) && script.count == 1 }
        await time.advance(by: 3600)
        try await holds("no inference while parked") { script.count == 1 }
        #expect(placements.withLock { $0 } == 0)
        #expect(try await sessions.generationState(id).generation == 0)
        #expect(try await sessions.promptRevision(id) == created)
        guard case .foldPending = try await sessions.hydrate(id).transcript.kernel.phase else { throw UnexpectedCall("a live phase after the park") }

        _ = try await space.fs(.shared).write("/AGENTS.md", Data("edited while parked".utf8), ifMatch: nil)
        _ = try await service.enqueue(item: Fix.message("next", message: "m2"), to: id)
        try await until("the wake runs the new generation") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(placements.withLock { $0 } == 1)
      #expect(try await sessions.generationState(id).generation == 1)
      #expect(try await sessions.promptRevision(id)! > created!)
    }
  }

  @Test func aRestartLeavesTheFoldPending() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "parks", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        parks(),
        { request in
          #expect(request.transcript.head?.summary == summary)
          #expect(request.transcript.carries(message: "after restart"))
          return Fix.reply("back")
        },
      ])
      let config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("wrap up"), to: id)
        try await until("the park settles") { try await sessions.settledWork(id) && script.count == 1 }
      }
      try await runService(space, config) { service in
        try await service.wake(id)
        try await holds("a restart starts nothing") { script.count == 1 }
        #expect(try await sessions.generationState(id).generation == 0)
        _ = try await service.enqueue(item: Fix.message("after restart", message: "m2"), to: id)
        try await until("the wake runs the new generation") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(try await sessions.generationState(id).generation == 1)
    }
  }

  @Test(arguments: [SessionKind.agent, .task])
  func aParkIsRefusedWhileTheSessionOwesAndTheTurnGoesOn(kind: SessionKind) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "parks owing", kind: kind, createdBy: "morgan", model: .test)
      let owing: QueueInput = switch kind {
      case .agent: Fix.message("please answer", conversation: id.rawValue, owesReply: true)
      case .task: .message(.init(
          id: UUID(), messageID: .init("r1"), conversationID: .init("dm"), sender: Fix.sender, timestamp: anchor,
          kind: .request, requestID: .init("r1"), content: .init(text: "do it"),
        ))
      }
      let script = InferenceScript([
        parks("parking without answering"),
        { request in
          guard case let .toolResult(result)? = request.transcript.items.last, case let .failure(failure) = result.payload else { throw UnexpectedCall("park refusal") }
          #expect(failure.message.hasPrefix(kind == .agent ? "owesReply: " : "owesReport: "))
          #expect(request.transcript.phase == .live)
          return Fix.reply("answering instead")
        },
        { _ in Fix.reply("still owing") },
      ])
      let config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      try await runService(space, config) { service in
        _ = try await service.enqueue(item: owing, to: id)
        try await until("the refused park's turn goes on and its nag is answered") { try await sessions.settledWork(id) && script.count == 3 }
      }
      #expect(try await sessions.generationState(id).generation == 0)
      #expect(try await sessions.hydrate(id).transcript.kernel.phase == .live)
    }
  }

  @Test func aCompactRequestFindsAPendingFoldCompactedAlready() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "parks", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        parks(),
        { request in
          #expect(request.transcript.head?.summary == summary)
          #expect(!request.transcript.items.contains { if case let .notification(notice) = $0 { notice.kind == .compactRequest } else { false } })
          return Fix.reply("on it")
        },
      ])
      let config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("wrap up"), to: id)
        try await until("the park settles") { try await sessions.settledWork(id) && script.count == 1 }
        try await sessions.requestCommand(id, .compact(instructions: "keep the build notes"))
        try await service.wake(id)
        try await until("the request completes") { try await sessions.pendingCommand(id) == nil }
        try await holds("no fold and no inference") { script.count == 1 }
        #expect(try await sessions.generationState(id).generation == 0)
        guard case .foldPending = try await sessions.hydrate(id).transcript.kernel.phase else { throw UnexpectedCall("the request ran the fold") }
        _ = try await service.enqueue(item: Fix.message("next", message: "m2"), to: id)
        try await until("the wake runs the fold") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(try await sessions.generationState(id).generation == 1)
    }
  }

  @Test func startOverDiscardsAPendingFold() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "parks", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        parks(),
        { request in
          #expect(request.transcript.head?.summary == "")
          #expect(!request.transcript.items.contains { if case let .toolResult(result) = $0, case .compact = result.payload { true } else { false } })
          return Fix.reply("fresh")
        },
      ])
      let config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      try await runService(space, config) { service in
        _ = try await service.enqueue(item: Fix.message("wrap up"), to: id)
        try await until("the park settles") { try await sessions.settledWork(id) && script.count == 1 }
        _ = try await service.restart(id, executor: nil, note: "Started over.")
        try await holds("Start over is inert") { script.count == 1 }
        _ = try await service.enqueue(item: Fix.message("begin again", message: "m2"), to: id)
        try await until("the fresh generation runs") { try await sessions.settledWork(id) && script.count == 2 }
      }
    }
  }

  @Test func aMissingBookmarkRefusesTheParkAndTheTurnGoesOn() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let id = try await sessions.createSession(group: .shared, title: "parks", kind: .agent, createdBy: "morgan", model: .test)
      let script = InferenceScript([
        Fix.replying("parking", calls: [parkingCompact(bookmark: "nowhere")]),
        { request in
          guard case let .toolResult(result)? = request.transcript.items.last, case let .failure(failure) = result.payload else { throw UnexpectedCall("missing bookmark refusal") }
          #expect(failure.message.contains("bookmark \"nowhere\" not found"))
          return Fix.reply("staying live")
        },
      ])
      try await runService(space, makeConfig(inference: { try await script($0) })) { service in
        _ = try await service.enqueue(item: Fix.message("wrap up"), to: id)
        try await until("the refusal is answered") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(try await sessions.hydrate(id).transcript.kernel.phase == .live)
    }
  }
}
