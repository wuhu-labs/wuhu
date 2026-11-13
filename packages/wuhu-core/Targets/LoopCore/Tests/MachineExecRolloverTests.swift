#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import JSONValue
@testable import LoopCore
import OperationProtocol
import Scratch
import SessionDomain
import SessionTools
@testable import SpaceCore
import StructuredQueries
import Testing
import WuhuAI
import Wuwei
import struct Wuwei.Database

@Job private struct StrandedExec {
  static let kind = ToolCallJob.kind
  static let schema = ToolCallJob.schema
  typealias Message = ToolCallJob.Message
  struct Params: Codable, Sendable {
    var session: SessionID
    var generation: Int
    var position: Int
    var call: ToolCall
    var yieldBy: Date?
    var machine: String
    var request: MachineExec
  }

  static func create(ctx: inout JobContext<Self>) throws {
    let target = ToolExecTarget(machine: ctx.params.machine, id: ctx.params.request.id, waitUntil: ctx.params.request.createdAt.addingTimeInterval(300), yieldBy: ctx.params.yieldBy)
    try ctx.db.execute(CallRow.insert { CallRow(started: true, exec: target) })
  }

  nonisolated(nonsending) mutating func start() async throws -> Outcome {
    ctx.send(MachineCell.ID(ctx.params.machine)).start(ctx.params.request, finished: id.recipient.retyped())
    // A crash fixture: leave finished queued, as if the process died before its receive.
    do { try await ctx.sleep(for: .seconds(1000)) } catch is CancellationError {}
    return .notDone
  }
}

@Cell private struct ExecLaunch {
  mutating func launch(_ params: StrandedExec.Params) {
    ctx.create(StrandedExec.ID("stranded-call"), params: params)
  }
}

@Suite struct MachineExecRolloverTests {
  func attach(_ space: Space, machine: String, requests: Box<[BoxSocket.Outgoing]>) async throws -> Peer<BoxSocket> {
    let pubkey = try await seedBoxKey(space: space, machine: machine)
    return try #require(space.worker.attach(BoxSocket.self, to: MachineCell.ID(machine), opening: .init(connection: UUID(), pubkey: pubkey, streams: 32)) {
      if case let .frame(frame) = $0 { requests.withLock { $0.append(frame) } }
    })
  }

  func describe(_ peer: Peer<BoxSocket>, _ space: Space, _ machine: String) async throws {
    peer.send(.init(tag: .describe, answer: .description(.init(instance: UUID(), acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec]))))
    try await until("the redial describes") { space.worker.cell(MachineCell.ID(machine)).db.rows(MachinePresence.all).first?.state == "attached" }
  }

  func output(_ text: String, _ exec: MachineExec, peer: Peer<BoxSocket>, space: Space, from: UInt64, ended: Bool, exitCode: Int = 0) throws {
    let bytes = Data(text.utf8)
    let through = from + UInt64(bytes.count)
    let pointer = try #require(space.machineBuffers.put(bytes, operation: exec.operation, channel: "stdout", from: from))
    let snapshot = OperationSnapshot(
      operation: exec.operation,
      verdict: ended ? .init(.completed, result: ["termination": ["tag": "exit", "code": .number(Double(exitCode))]]) : nil,
      terminalToken: ended ? UUID() : nil,
      finalOffsets: ended ? ["stdout": .init(rawValue: through), "stderr": .zero] : [:],
      outputConsumed: false,
      channel: "stdout",
      from: .init(rawValue: from),
      through: .init(rawValue: through),
    )
    peer.send(.init(tag: .operation(exec.operation, .output("stdout")), answer: .snapshot(.init(snapshot: snapshot, output: pointer, tail: bytes))))
  }

  @Test func `a committed finish stranded before drain is taken by the replacement job once`() async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("stranded-exec-roll")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let seeding = SessionExecution(space: old, loopConfig: makeConfig())
      let session = try await old.sessions.createSession(group: .shared, title: "stranded", kind: .agent, createdBy: "owner", model: .test)
      await seeding.shutdown()
      let machine = "stranded-box"
      let cell = MachineCell.ID(machine)
      old.worker.register(.job(StrandedExec.self))
      old.worker.register(.cell(ExecLaunch.self))
      old.worker.start()
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(old, machine: machine, requests: requests)
      try await describe(peer, old, machine)
      let request = MachineExec(id: "stranded-exec", operation: UUID(), createdAt: anchor, group: .shared, caller: session.rawValue, session: session, toolCall: .init("call"), argv: ["echo", "tail"])
      let params = StrandedExec.Params(session: session, generation: 0, position: 0, call: .init(id: "call", name: "exec", arguments: .object(["machine": .string(machine), "cwd": "/tmp", "command": "echo tail"])), machine: machine, request: request)
      try await old.worker.call(ExecLaunch.ID("launch")) { $0.launch(params) }
      try await until("start is dispatched") { old.worker.cell(cell).operation(request.id)?.dispatched == true }
      peer.send(.init(tag: .operation(request.operation, .start), answer: .snapshot(.init(snapshot: .init(operation: request.operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false)))))
      try await until("start is answered") { old.worker.cell(cell).operation(request.id)?.state == "running" }
      try output("retained tail", request, peer: peer, space: old, from: 0, ended: true, exitCode: 23)
      try await until("finished commits before the old worker drains") { old.worker.cell(cell).operation(request.id)?.delivered == true }
      #expect(old.worker.cell(cell).tail(request.id) == Data("retained tail".utf8))
      #expect(old.worker.hasMail(for: ToolCallJob.ID("stranded-call").recipient))

      new.worker.provide(withEscapedDependencies { dependencies in
        LoopClient(
          space: new,
          scripts: Scripts(),
          tools: ToolExecutor(main: MainConnection(), credential: { _ in throw MainUnavailable() }),
          store: new.sessions,
          config: makeConfig(),
          sleep: { _ in { throw UnexpectedCall("sleep") } },
          dependencies: dependencies,
          scheduler: new.worker.scheduler,
          handler: { _ in throw UnexpectedCall("handler") },
        )
      })
      new.worker.register(.job(ToolCallJob.self))
      new.worker.start()
      await old.stopWorker()
      await time.advance(by: 2)
      let job = ToolCallJob.ID("stranded-call")
      try await until("replacement takes the stranded finish") {
        new.worker.job(job).db.rows(CallRow.all).first?.answer != nil
          && new.worker.cell(cell).operation(request.id)?.recipient == nil
      }
      #expect(new.worker.cell(cell).operation(request.id)?.background == false)
      let answer = try #require(new.worker.job(job).db.rows(CallRow.all).first?.answer)
      guard case let .result(.exec(result), _) = answer else {
        Issue.record("the replacement must return the real exec result")
        throw UnexpectedCall("replacement answer")
      }
      #expect(result.output == "retained tail")
      #expect(result.exitCode == 23)
      #expect(new.worker.cell(cell).tail(request.id).isEmpty)
      let mails = try RawDatabase.open(new.databasePath) {
        try $0.rows("SELECT payload FROM wuwei_mail WHERE recipient = ?", arguments: [SessionCell.ID(session.rawValue).description]).map { row in
          let payload: Data = row[0]
          return payload
        }
      }
      let values = try mails.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
      let calledCount = values.filter { $0.object?["called"] != nil }.count
      #expect(calledCount == 1)
      #expect(!values.contains { $0.object?["put"] != nil })
      #expect(mails.filter { String(decoding: $0, as: UTF8.self).contains("serverRestarted") }.isEmpty)
      let tailCount = mails.filter { String(decoding: $0, as: UTF8.self).contains("retained tail") }.count
      #expect(tailCount == 1)
      let replacementRequests = Box<[BoxSocket.Outgoing]>([])
      let redial = try await attach(new, machine: machine, requests: replacementRequests)
      try await describe(redial, new, machine)
      #expect(!replacementRequests.value.contains { if case .start = $0.exchange { true } else { false } })
      try await until("redial acknowledges the committed output") { replacementRequests.value.contains { if case let .poll(_, _, after, _, _, _) = $0.exchange { after == 13 } else { false } } }
      redial.close()
      try await old.close()
      try await new.close()
    }
  }

  @Test func `a real tool job resumes its live exec after drain and returns one actual result`() async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("exec-roll")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let call = ToolCall(id: "call", name: "exec", arguments: .object(["machine": .string("rollbox"), "cwd": .string("/tmp"), "command": .string("echo tail")]))
      let script = InferenceScript([Fix.replying("running", calls: [call]), Fix.replying("resumed"), Fix.replying("noted")])
      let config = makeConfig(inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let session = try await old.sessions.createSession(group: .shared, title: "exec", kind: .agent, createdBy: "owner", model: .test)
      let machine = try await old.addMachineV2(name: "rollbox").machine
      let second = SessionExecution(space: new, loopConfig: config)
      first.start()
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(old, machine: machine.id.rawValue, requests: requests)
      try await describe(peer, old, machine.id.rawValue)
      try await first.enqueue(item: Fix.message("run"), to: session)
      let requestBox = Box<MachineExec?>(nil)
      try await until("the tool mails start") {
        for frame in requests.value { if case let .start(exec) = frame.exchange { requestBox.withLock { $0 = exec }; return true } }
        return false
      }
      let request = try #require(requestBox.value)
      peer.send(.init(tag: .operation(request.operation, .start), answer: .snapshot(.init(snapshot: .init(operation: request.operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false)))))
      try output("before ", request, peer: peer, space: old, from: 0, ended: false)
      let cell = MachineCell.ID(machine.id.rawValue)
      try await until("old output commits") { old.worker.cell(cell).operation(request.id)?.stdout == 7 }
      let turn = try #require(old.worker.cell(SessionCell.ID(session.rawValue)).turn())
      let job = Slot(session: session, generation: turn.generation, position: turn.position, stepTry: 0).call
      second.start()
      await first.shutdown()
      #expect(!requests.value.contains { if case .stop = $0.exchange { true } else { false } })
      await time.advance(by: 2)
      #expect(new.worker.cell(cell).operation(request.id)?.background == false)
      #expect(try await new.sessions.lines(session).filter { $0.role == .toolResult }.isEmpty)
      let redialRequests = Box<[BoxSocket.Outgoing]>([])
      let redial = try await attach(new, machine: machine.id.rawValue, requests: redialRequests)
      try await describe(redial, new, machine.id.rawValue)
      try output("after", request, peer: redial, space: new, from: 7, ended: true, exitCode: 23)
      await time.advance(by: 2)
      try await until("session has one actual tool result") {
        try await new.sessions.lines(session).filter { $0.role == .toolResult }.count == 1
      }
      try await until("the session settles without a completion notice") { try await new.sessions.settledWork(session) }
      let lines = try await new.sessions.lines(session)
      #expect(lines.filter { $0.role == .toolResult }.map(\.text) == ["before after\n(exit code 23)"])
      #expect(lines.filter { $0.text.contains("before after") }.count == 1)
      #expect(!lines.contains { $0.text.contains(serverRestartedToolMessage) })
      #expect(new.worker.cell(cell).operation(request.id)?.background == false)
      #expect(new.worker.cell(cell).operation(request.id)?.recipient == nil)
      #expect(new.worker.cell(cell).tail(request.id).isEmpty)
      let answer = try #require(new.worker.job(job).db.rows(CallRow.all).first?.answer)
      guard case let .result(.exec(result), _) = answer else {
        Issue.record("the resumed job must return the real exec result")
        throw UnexpectedCall("resumed answer")
      }
      #expect(result.exitCode == 23)
      #expect(!redialRequests.value.contains { if case .start = $0.exchange { true } else { false } })
      redial.close()
      await second.shutdown()
      try await old.close()
      try await new.close()
    }
  }
}

extension MachineExecRolloverTests {
  @Test func `a resumed exec returns running once at its original absolute wait deadline`() async throws {
    try await rolloverDeadline(yielding: false)
  }

  @Test func `a resumed exec preserves its earliest committed yield deadline`() async throws {
    try await rolloverDeadline(yielding: true)
  }

  private func rolloverDeadline(yielding: Bool) async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("exec-deadline-roll")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let wait: Double = yielding ? 12 : 8
      let deadline = anchor.addingTimeInterval(yielding ? 6 : wait)
      let call = ToolCall(id: "call", name: "exec", arguments: .object(["machine": "deadlinebox", "cwd": "/tmp", "command": "echo tail", "wait_seconds": .number(wait)]))
      let script = InferenceScript([Fix.replying("running", calls: [call]), Fix.replying("returned"), Fix.replying("ended")])
      let config = makeConfig(inference: { try await script($0) })
      let first = SessionExecution(space: old, loopConfig: config)
      let session = try await old.sessions.createSession(group: .shared, title: "deadline", kind: .agent, createdBy: "owner", model: .test)
      let machine = try await old.addMachineV2(name: "deadlinebox").machine
      let second = SessionExecution(space: new, loopConfig: config)
      first.start()
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(old, machine: machine.id.rawValue, requests: requests)
      try await describe(peer, old, machine.id.rawValue)
      try await first.enqueue(item: Fix.message("run"), to: session)
      let requestBox = Box<MachineExec?>(nil)
      try await until("the deadline test dispatches one start") {
        for frame in requests.value { if case let .start(exec) = frame.exchange { requestBox.withLock { $0 = exec }; return true } }
        return false
      }
      let request = try #require(requestBox.value)
      let cell = MachineCell.ID(machine.id.rawValue)
      peer.send(.init(tag: .operation(request.operation, .start), answer: .snapshot(.init(snapshot: .init(operation: request.operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false)))))
      try output("before ", request, peer: peer, space: old, from: 0, ended: false)
      try await until("output before the deadline commits") { old.worker.cell(cell).operation(request.id)?.stdout == 7 }
      let turn = try #require(old.worker.cell(SessionCell.ID(session.rawValue)).turn())
      let job = Slot(session: session, generation: turn.generation, position: turn.position, stepTry: 0).call
      #expect(old.worker.job(job).db.rows(CallRow.all).first?.exec?.waitUntil == anchor.addingTimeInterval(wait))
      await time.advance(to: anchor.addingTimeInterval(2))
      if yielding {
        old.worker.send(.yield(by: deadline), to: job)
        old.worker.send(.yield(by: deadline.addingTimeInterval(1)), to: job)
        try await until("both yields commit with the earliest deadline") {
          old.worker.job(job).db.rows(CallRow.all).first?.exec?.yieldBy == deadline && !old.worker.hasMail(for: job.recipient)
        }
      }
      second.start()
      await first.shutdown()
      #expect(!requests.value.contains { if case .stop = $0.exchange { true } else { false } })
      await time.advance(to: anchor.addingTimeInterval(4))
      let redialRequests = Box<[BoxSocket.Outgoing]>([])
      let redial = try await attach(new, machine: machine.id.rawValue, requests: redialRequests)
      try await describe(redial, new, machine.id.rawValue)
      try await until("the replacement waits only the remaining absolute interval") {
        time.sleeping(dueIn: deadline.timeIntervalSince(anchor) - 4) > 0
      }
      #expect(new.worker.job(job).db.rows(CallRow.all).first?.exec?.waitUntil == anchor.addingTimeInterval(wait))
      #expect(new.worker.job(job).db.rows(CallRow.all).first?.exec?.yieldBy == (yielding ? deadline : nil))
      #expect(new.worker.cell(cell).operation(request.id)?.background == false)
      await time.advance(to: deadline.addingTimeInterval(-0.5))
      try await holds("no tool result before the original deadline") {
        try await new.sessions.lines(session).filter { $0.role == .toolResult }.isEmpty
      }
      await time.advance(to: deadline.addingTimeInterval(0.001))
      try await until("the original deadline returns running") {
        try await new.sessions.lines(session).filter { $0.role == .toolResult }.count == 1
      }
      let answers = try await new.sessions.lines(session).filter { $0.role == .toolResult }
      #expect(answers[0].text.contains("running"))
      #expect(answers[0].text.contains("exec." + request.id))
      #expect(answers[0].text.contains("before "))
      #expect(!answers[0].text.contains(serverRestartedToolMessage))
      try await until("the deadline backgrounds the same exec") { new.worker.cell(cell).operation(request.id)?.background == true }
      try output("after", request, peer: redial, space: new, from: 7, ended: true)
      try await until("the detached exec completes through its one session notice") {
        try await new.sessions.lines(session).contains { $0.role != .toolResult && $0.text.contains("before after") }
      }
      await time.advance(to: anchor.addingTimeInterval(13))
      try await until("the completed session settles") { try await new.sessions.settledWork(session) }
      let lines = try await new.sessions.lines(session)
      #expect(lines.filter { $0.role == .toolResult }.count == 1)
      #expect(lines.filter { $0.role != .toolResult && $0.text.contains("before after") }.count == 1)
      #expect(requests.value.filter { if case .start = $0.exchange { true } else { false } }.count == 1)
      #expect(!redialRequests.value.contains { if case .start = $0.exchange { true } else { false } })
      redial.close()
      await second.shutdown()
      try await old.close()
      try await new.close()
    }
  }

  enum Ending: CaseIterable { case finished, interrupted, waited, killed }

  @Test(arguments: Ending.allCases)
  func `a real exec job takes its finish or detaches on wait but never notifies after interrupt`(_ ending: Ending) async throws {
    try await withKernelDeps { time in
      let space = try Space.inMemory()
      let call = ToolCall(id: "call", name: "exec", arguments: .object(["machine": "jobbox", "cwd": "/tmp", "command": "echo tail", "wait_seconds": 1]))
      let script = InferenceScript([Fix.replying("running", calls: [call]), Fix.replying("noted"), Fix.replying("ended")])
      let service = SessionExecution(space: space, loopConfig: makeConfig(inference: { try await script($0) }))
      let session = try await space.sessions.createSession(group: .shared, title: "exec", kind: .agent, createdBy: "owner", model: .test)
      let machine = try await space.addMachineV2(name: "jobbox").machine
      service.start()
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(space, machine: machine.id.rawValue, requests: requests)
      try await describe(peer, space, machine.id.rawValue)
      try await service.enqueue(item: Fix.message("run"), to: session)
      let requestBox = Box<MachineExec?>(nil)
      try await until("the actual job sends start") {
        for frame in requests.value { if case let .start(exec) = frame.exchange { requestBox.withLock { $0 = exec }; return true } }
        return false
      }
      let request = try #require(requestBox.value)
      let cell = MachineCell.ID(machine.id.rawValue)
      peer.send(.init(tag: .operation(request.operation, .start), answer: .snapshot(.init(snapshot: .init(operation: request.operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false)))))
      try await until("start commits") { space.worker.cell(cell).operation(request.id)?.state == "running" }
      if ending == .interrupted {
        try await service.interrupt(session)
        try await until("interrupt stops without detaching") { space.worker.cell(cell).operation(request.id)?.stop == "callerCancelled" }
        #expect(space.worker.cell(cell).operation(request.id)?.background == false)
        #expect(space.worker.cell(cell).operation(request.id)?.recipient == nil)
      } else if ending == .killed {
        try await space.worker.call(cell) { try $0.stop(request.id, reason: "callerCancelled") }
        #expect(space.worker.cell(cell).operation(request.id)?.recipient != nil)
      } else if ending == .waited {
        try await time.wake("the exec wait", after: 1)
        try await until("wait detaches to the session") { space.worker.cell(cell).operation(request.id)?.background == true }
      }
      try output("job tail", request, peer: peer, space: space, from: 0, ended: true)
      try await until("the terminal verdict commits") { space.worker.cell(cell).operation(request.id)?.delivered == true }
      try await until("the tool has exactly one answer") { try await space.sessions.lines(session).filter { $0.role == .toolResult }.count == 1 }
      try await until("tail has been taken or dropped") { space.worker.cell(cell).tail(request.id).isEmpty }
      if ending == .waited {
        try await until("one session completion") { try await space.sessions.lines(session).contains { $0.role != .toolResult && $0.text.contains("job tail") } }
      }
      let lines = try await space.sessions.lines(session)
      let answers = lines.filter { $0.role == .toolResult }
      switch ending {
      case .finished, .killed:
        #expect(answers.map(\.text) == ["job tail"])
        #expect(lines.filter { $0.text.contains("job tail") }.count == 1)
      case .interrupted:
        #expect(answers.map(\.text) == [interruptedToolMessage])
        #expect(!lines.contains { $0.text.contains("job tail") })
      case .waited:
        #expect(answers[0].text.contains("running"))
        #expect(lines.filter { $0.role != .toolResult && $0.text.contains("job tail") }.count == 1)
      }
      peer.close()
      await service.shutdown()
      try await space.close()
    }
  }
}

extension MachineExecRolloverTests {
  @Test(arguments: [false, true]) func `script caller loss is owned by the stream and replacement machine wake`(drain: Bool) async throws {
    try await withKernelDeps { time in
      let folder = try ScratchFolder("script-exec-stream")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      let seeding = SessionExecution(space: old, loopConfig: makeConfig())
      let session = try await old.sessions.createSession(group: .shared, title: "script", kind: .agent, createdBy: "owner", model: .test)
      await seeding.shutdown()
      old.worker.start()
      let machine = try await old.addMachineV2(name: "scriptbox").machine
      let cell = MachineCell.ID(machine.id.rawValue)
      let requests = Box<[BoxSocket.Outgoing]>([])
      let peer = try await attach(old, machine: machine.id.rawValue, requests: requests)
      try await describe(peer, old, machine.id.rawValue)
      let reserved = try await old.reserveExec(machine: machine.id, caller: session.rawValue, script: "12345678")
      var reservedRequest = old.worker.cell(cell).operation(reserved.id.rawValue)!.request
      reservedRequest.argv = ["sh", "-c", "sleep 1000"]
      reservedRequest.window = 1 << 20
      let request = reservedRequest
      let stream = try #require(old.worker.attach(ExecStream.self, to: cell, opening: .init(exec: request, nonce: UUID())) { _ in })
      try await until("the stream starts the process") { old.worker.cell(cell).operation(request.id)?.dispatched == true }
      peer.send(.init(tag: .operation(request.operation, .start), answer: .snapshot(.init(snapshot: .init(operation: request.operation, verdict: nil, terminalToken: nil, finalOffsets: [:], outputConsumed: false)))))
      try await until("the start is answered") { old.worker.cell(cell).operation(request.id)?.state == "running" }
      await #expect(throws: OperationError.self) {
        try await old.worker.call(cell) { try $0.background(request.id) }
      }
      if drain {
        new.worker.start()
        await old.stopWorker()
        await time.advance(by: 2)
        let redial = try await attach(new, machine: machine.id.rawValue, requests: requests)
        try await describe(redial, new, machine.id.rawValue)
        try await new.worker.call(cell) { try $0.wake() }
        try await until("the replacement detects the orphan without script-job mail") { new.worker.cell(cell).operation(request.id)?.stop == "callerGone" }
        redial.close()
      } else {
        stream.close()
        try await until("the stream closure stops its exec") { old.worker.cell(cell).operation(request.id)?.stop == "callerGone" }
      }
      try await old.close()
      try await new.close()
    }
  }
}
