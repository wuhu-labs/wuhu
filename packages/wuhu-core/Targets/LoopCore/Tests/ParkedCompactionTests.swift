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

@Suite struct ParkedCompactionTests {
  @Test func parkWithAModelIsATypedRefusal() {
    #expect(throws: CompactArgumentsError.parkWithModel) { _ = try decodeArguments(CompactArguments.self, from: parkingCompact(model: "work")) }
  }

  @Test func aParkedCompactionRunsNothingUntilAWakeStartsItsGeneration() async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let placements = Mutex(0)
      let script = InferenceScript([
        parks(),
        { request in
          #expect(request.lines.first { $0.key == "head:summary" }?.text == "<conversation-summary>\n\(summary)\n</conversation-summary>")
          #expect(request.lines.first { $0.key == LineKey.head }?.text.contains("files to re-read (re-established below): /notes.md") == true)
          #expect(request.lines.contains { $0.key == "message:m2" && $0.role == .user && $0.text.hasSuffix("\n\nnext") })
          return Fix.reply("on it")
        },
      ])
      var config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      config.prepareCompaction = { _, _, _ in
        placements.withLock { $0 += 1 }
        return nil
      }
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await sessions.createSession(group: .shared, title: "parks", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("wrap up"), to: id)
        try await until("the park settles") { try await sessions.settledWork(id) && script.count == 1 }
        await time.advance(by: 3600)
        try await holds("no inference while parked") { script.count == 1 }
        #expect(placements.withLock { $0 } == 0)
        #expect(try await sessions.generationState(id).generation == 0)
        #expect(try await sessions.promptRevisions(id) == nil)
        guard case .folding? = space.worker.cell(SessionCell.ID(id.rawValue)).turn()?.turn else { throw UnexpectedCall("a live turn after the park") }

        _ = try await space.fs(.shared).write("/AGENTS.md", Data("edited while parked".utf8), ifMatch: nil)
        try await service.enqueue(item: Fix.message("next", message: "m2"), to: id)
        try await until("the wake runs the new generation") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(placements.withLock { $0 } == 1)
      #expect(try await sessions.generationState(id).generation == 1)
      #expect(try await sessions.promptRevisions(id) == nil)
    }
  }

  @Test func aRestartLeavesTheFoldPending() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([
        parks(),
        { request in
          #expect(request.lines.first { $0.key == "head:summary" }?.text == "<conversation-summary>\n\(summary)\n</conversation-summary>")
          #expect(request.lines.contains { $0.key == "message:m2" && $0.role == .user && $0.text.hasSuffix("\n\nafter restart") })
          return Fix.reply("back")
        },
      ])
      let config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await sessions.createSession(group: .shared, title: "parks", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("wrap up"), to: id)
        try await until("the park settles") { try await sessions.settledWork(id) && script.count == 1 }
      }
      try await runService(space, config) { service in
        try await sessions.look(id)
        try await holds("a restart starts nothing") { script.count == 1 }
        #expect(try await sessions.generationState(id).generation == 0)
        try await service.enqueue(item: Fix.message("after restart", message: "m2"), to: id)
        try await until("the wake runs the new generation") { try await sessions.settledWork(id) && script.count == 2 }
      }
      #expect(try await sessions.generationState(id).generation == 1)
    }
  }

  @Test func aRequestThatMentionsAnotherSessionReachesItAsAMessageAndLeavesItFreeToPark() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([parks()])
      let config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let bystander = try await sessions.createSession(group: .shared, title: "bystander", kind: .agent, createdBy: "morgan", model: .test)
      let requester = try await createRetiredSession(in: space, title: "requester", createdBy: "morgan")
      let task = try await createRetiredSession(in: space, title: "task", kind: .task, parent: requester, createdBy: "morgan")
      try await runService(service) { _ in
        _ = try await sessions.openRequest(on: task, from: .session(requester), messageID: .init("r1"), text: "ask @\(bystander.rawValue) first")
        try await until("the bystander's park settles") { try await sessions.settledWork(bystander) && script.count == 1 }
        guard case .folding? = space.worker.cell(SessionCell.ID(bystander.rawValue)).turn()?.turn else { throw UnexpectedCall("the park was refused") }
      }
      let lines = try await sessions.lines(bystander)
      let copy = try #require(lines.first { $0.key == "message:r1" })
      #expect(copy.role == .user)
      #expect(copy.text.contains("<type>message</type>"))
      #expect(!copy.text.contains("<type>request</type>"))
      #expect(try sessions.openRequests(bystander).isEmpty)
      #expect(try sessions.openRequests(task).map(\.id) == [RequestID("r1")])
    }
  }

  @Test func aRequestBriefDeliveredToASessionThatIsNotItsTaskLeavesItFreeToPark() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([parks()])
      let config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let bystander = try await sessions.createSession(group: .shared, title: "bystander", kind: .agent, createdBy: "morgan", model: .test)
      let requester = try await createRetiredSession(in: space, title: "requester", createdBy: "morgan")
      let task = try await createRetiredSession(in: space, title: "task", kind: .task, parent: requester, createdBy: "morgan")
      _ = try await sessions.openRequest(on: task, from: .session(requester), messageID: .init("r1"), text: "do it")
      let foreignBrief = QueueInput.message(.init(
        id: UUID(), messageID: .init("r1"), conversationID: .init("dm-requester-task"), sender: Fix.sender,
        timestamp: anchor, kind: .request, requestID: .init("r1"), owesReply: false, content: .init(text: "do it"),
      ))
      try await runService(service) { service in
        try await service.enqueue(item: foreignBrief, to: bystander)
        try await until("the bystander's park settles") { try await sessions.settledWork(bystander) && script.count == 1 }
        guard case .folding? = space.worker.cell(SessionCell.ID(bystander.rawValue)).turn()?.turn else { throw UnexpectedCall("the park was refused") }
      }
      #expect(try sessions.openRequests(task).map(\.id) == [RequestID("r1")])
    }
  }

  @Test func aTaskWhoseRequestFailedParks() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([parks()])
      let config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let task = try await createRequestedTask(in: space, title: "fails its request")
      try await sessions.markInterrupted(task)
      let parent = try #require(try await sessions.record(task).parent)
      let schema = try #require(JSONValue.parse(#"{"type":"object"}"#))
      _ = try await sessions.openRequest(on: task, from: .session(parent), messageID: .init("r1"), text: "answer in JSON", terms: RequestTerms(schema: schema))
      for attempt in ["f1", "f2", "f3"] {
        await #expect(throws: SessionStoreError.self) {
          _ = try await sessions.report(task, request: .init("r1"), kind: .final, messageID: .init(attempt), text: "not an object")
        }
      }
      #expect(try sessions.openRequests(task).isEmpty)
      try await runService(service) { service in
        try await service.resume(task)
        try await until("the task's park settles") { try await sessions.settledWork(task) && script.count == 1 }
        guard case .folding? = space.worker.cell(SessionCell.ID(task.rawValue)).turn()?.turn else { throw UnexpectedCall("the park was refused") }
      }
      let lines = try await sessions.lines(task)
      #expect(lines.contains { $0.key == "message:r1" && $0.text.contains("<type>request</type>") })
    }
  }

  @Test(arguments: [SessionKind.agent, .task])
  func aParkIsRefusedWhileTheSessionOwesAndTheTurnGoesOn(kind: SessionKind) async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([
        parks("parking without answering"),
        { request in
          let result = try #require(request.lines.last)
          #expect(result.role == .toolResult)
          #expect(result.message.toolResult?.isError == true)
          #expect(result.text.hasPrefix(kind == .agent ? "owesReply: " : "owesReport: "))
          return Fix.reply("answering instead")
        },
        { _ in Fix.reply("still owing") },
      ])
      let config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await kind == .agent
        ? sessions.createSession(group: .shared, title: "parks owing", kind: kind, createdBy: "morgan", model: .test)
        : createRequestedTask(in: space, title: "parks owing")
      let owing: QueueInput? = kind == .agent ? Fix.message("please answer", conversation: id.rawValue, owesReply: true) : nil
      try await runService(service) { service in
        if let owing { try await service.enqueue(item: owing, to: id) } else { try await sessions.openParentRequest(on: id) }
        try await until("the refused park's turn goes on and its nag is answered") { try await sessions.settledWork(id) && script.count == 3 }
        #expect(space.worker.cell(SessionCell.ID(id.rawValue)).turn()?.turn == .idle)
      }
      #expect(try await sessions.generationState(id).generation == 0)
    }
  }

  @Test func startOverDiscardsAPendingFold() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([
        parks(),
        { request in
          #expect(request.lines.first?.key == LineKey.head)
          #expect(!request.lines.contains { $0.key == "head:summary" || $0.role == .toolResult })
          return Fix.reply("fresh")
        },
      ])
      let config = makeConfig(executeTool: { _ in .failure(.init(message: "no file")) }, inference: { try await script($0) })
      let service = SessionExecution(space: space, loopConfig: config)
      let id = try await sessions.createSession(group: .shared, title: "parks", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("wrap up"), to: id)
        try await until("the park settles") { try await sessions.settledWork(id) && script.count == 1 }
        _ = try await service.restart(id, executor: nil, note: "Started over.")
        try await holds("Start over is inert") { script.count == 1 }
        try await service.enqueue(item: Fix.message("begin again", message: "m2"), to: id)
        try await until("the fresh generation runs") { try await sessions.settledWork(id) && script.count == 2 }
      }
    }
  }

  @Test func aMissingBookmarkRefusesTheParkAndTheTurnGoesOn() async throws {
    try await withKernelDeps { _ in
      let space = try Space.inMemory()
      let sessions = space.sessions
      let script = InferenceScript([
        Fix.replying("parking", calls: [parkingCompact(bookmark: "nowhere")]),
        { request in
          let result = try #require(request.lines.last)
          #expect(result.role == .toolResult)
          #expect(result.message.toolResult?.isError == true)
          #expect(result.text.contains("bookmark \"nowhere\" not found"))
          return Fix.reply("staying live")
        },
      ])
      let service = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      let id = try await sessions.createSession(group: .shared, title: "parks", kind: .agent, createdBy: "morgan", model: .test)
      try await runService(service) { service in
        try await service.enqueue(item: Fix.message("wrap up"), to: id)
        try await until("the refusal is answered") { try await sessions.settledWork(id) && script.count == 2 }
        #expect(space.worker.cell(SessionCell.ID(id.rawValue)).turn()?.turn == .idle)
      }
      #expect(try await sessions.generationState(id).generation == 0)
    }
  }
}
