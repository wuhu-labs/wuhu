import Foundation
import InferenceKit
import MachineChannel
@testable import MainHub
import SessionDomain
import SpaceContract
import SpaceCore
import Synchronization
import Testing
import WuhuAI

// A worker that answers as told and remembers what it was asked.
private final class Recorder: Worker, Sendable {
  let asked = Mutex<[String]>([])
  let refuse: (any Error & Sendable)?
  let gate = AsyncStream<Void>.makeStream()

  init(refuse: (any Error & Sendable)? = nil) { self.refuse = refuse }

  private func note(_ call: String) throws {
    asked.withLock { $0.append(call) }
    if let refuse { throw refuse }
  }

  func deliver(_ session: SessionID, _ input: WorkerInput) async throws { try note("deliver \(session.rawValue) \(input)") }
  func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool {
    try note("revoke \(session.rawValue) \(policy)")
    for await _ in gate.0 { break }
    return policy == .handOff
  }

  func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult {
    try note("fire \(invocation.path)")
    guard case let .rows(rows) = invocation.input else { return ScriptHandlerResult(stateJSON: "timer", wakes: []) }
    return ScriptHandlerResult(stateJSON: "\(rows.rows)", wakes: rows.columns)
  }

  // Says each argument as an update and its source as the result; a source
  // of "hold" runs until it is cancelled.
  func run(_ script: ScriptRun, output: @escaping @Sendable (ScriptOutput) -> Void) async throws {
    try note("run \(script.source)")
    for argument in script.arguments { output(.update(text: argument)) }
    guard script.source == "hold" else { return output(.result(text: script.source)) }
    let (never, _) = AsyncStream<Void>.makeStream()
    for await _ in never {}
    asked.withLock { $0.append("cancelled") }
    throw CancellationError()
  }

  func activity() async -> WorkerActivity { WorkerActivity(scripts: [ScriptRunID("s1"): SessionID("a")]) }
  func runningWork(_ session: SessionID) async throws -> [String] {
    try note("running \(session.rawValue)")
    return ["exec.1", "script.s1"]
  }

  func shutdown() async { asked.withLock { $0.append("shutdown") } }
}

@Suite struct WorkerLineTests {
  private func line(_ worker: Recorder, _ body: (WorkerClient) async throws -> Void) async throws {
    let (main, other) = InMemoryTransport.pair()
    let client = WorkerClient(transport: main)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      group.addTask { await serveWorkerLine(worker, on: other) }
      try await body(client)
      main.close()
      try await group.waitForAll()
    }
  }

  @Test func eachCallCrossesAndComesBackAsItWasAnswered() async throws {
    let worker = Recorder()
    worker.gate.1.yield(())
    try await line(worker) { client in
      try await client.deliver(SessionID("a"), .wake)
      #expect(try await client.revoke(SessionID("a"), policy: .handOff))
      let rows = Rows(columns: ["n", "b"], decltypes: ["INTEGER", nil], rows: [[.integer(7), .blob([1, 2])], [.real(0.5), .null]])
      let handled = try await client.fire(.init(id: UUID(), path: "/h.js", session: SessionID("a"), input: .rows(rows), stateJSON: nil))
      #expect(handled.stateJSON == "\(rows.rows)" && handled.wakes == ["n", "b"])
      let timer = try await client.fire(.init(id: UUID(), path: "/t.js", session: SessionID("a"), input: .timer(Date(timeIntervalSince1970: 5)), stateJSON: "{}"))
      #expect(timer.stateJSON == "timer")
      #expect(await client.activity().scripts == [ScriptRunID("s1"): SessionID("a")])
      #expect(try await client.runningWork(SessionID("a")) == ["exec.1", "script.s1"])
      await client.shutdown()
    }
    #expect(worker.asked.withLock { $0 } == ["deliver a wake", "revoke a handOff", "fire /h.js", "fire /t.js", "running a", "shutdown"])
  }

  // A long call does not hold the line: the revoke waits for its step while
  // a wake goes through.
  @Test func callsRunSideBySide() async throws {
    let worker = Recorder()
    try await line(worker) { client in
      async let settled = client.revoke(SessionID("a"), policy: .whenSettled)
      while worker.asked.withLock({ $0.isEmpty }) { await Task.yield() }
      try await client.deliver(SessionID("b"), .interrupt)
      worker.gate.1.yield(())
      #expect(try await settled == false)
    }
  }

  @Test func aRunsOutputsCrossInOrderBeforeItsReply() async throws {
    let heard = Mutex<[ScriptOutput]>([])
    try await line(Recorder()) { client in
      try await client.run(ScriptRun(session: SessionID("a"), source: "done", arguments: ["one", "two"])) { output in
        heard.withLock { $0.append(output) }
      }
    }
    #expect(heard.withLock { $0 } == [.update(text: "one"), .update(text: "two"), .result(text: "done")])
  }

  @Test func cancellingARunOnMainCancelsItOnTheWorker() async throws {
    let worker = Recorder()
    try await line(worker) { client in
      let running = Task { try await client.run(ScriptRun(session: SessionID("a"), source: "hold", arguments: [])) { _ in } }
      while worker.asked.withLock({ $0.isEmpty }) { await Task.yield() }
      running.cancel()
      await #expect(throws: CancellationError.self) { try await running.value }
    }
    #expect(worker.asked.withLock { $0 } == ["run hold", "cancelled"])
  }

  @Test(arguments: [
    SessionError.archiveInProgress, .unreadableData(SessionID("a")), .archiveGraceExpired, .archiveReservationLost,
  ])
  func aSessionErrorKeepsItsKind(_ refusal: SessionError) async throws {
    try await line(Recorder(refuse: refusal)) { client in
      await #expect(throws: refusal) { try await client.deliver(SessionID("a"), .resume) }
    }
  }

  @Test func otherErrorsCrossByKindOrByWhatTheySay() async throws {
    try await line(Recorder(refuse: UnfulfilledError())) { client in
      await #expect(throws: UnfulfilledError.self) { try await client.deliver(SessionID("a"), .wake) }
    }
    try await line(Recorder(refuse: CancellationError())) { client in
      await #expect(throws: CancellationError.self) { try await client.deliver(SessionID("a"), .wake) }
    }
    struct Odd: Error, CustomStringConvertible { var description: String { "odd" } }
    try await line(Recorder(refuse: Odd())) { client in
      await #expect(throws: WorkerFailure(message: "odd")) { try await client.runningWork(SessionID("a")) }
    }
  }

  @Test func aCallLeftWaitingWhenTheLineClosesFailsAndSoDoesEveryCallAfter() async throws {
    let (main, other) = InMemoryTransport.pair()
    let client = WorkerClient(transport: main)
    let worker = Recorder()
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      group.addTask { await serveWorkerLine(worker, on: other) }
      let waiting = Task { try await client.revoke(SessionID("a"), policy: .handOff) }
      while worker.asked.withLock({ $0.isEmpty }) { await Task.yield() }
      other.close()
      await #expect(throws: WorkerLineSevered.self) { try await waiting.value }
      await #expect(throws: WorkerLineSevered.self) { try await client.deliver(SessionID("a"), .wake) }
      worker.gate.1.finish()
      try await group.waitForAll()
    }
  }
}

@Suite struct WorkerNoticeTests {
  @Test func noticesReachMainInTheOrderTheyWereSent() async throws {
    let (main, other) = InMemoryTransport.pair()
    let heard = Mutex<[String]>([])
    let client = WorkerClient(transport: main) { notice in
      switch notice {
      case let .attempt(session, .started(id)): heard.withLock { $0.append("started \(session.rawValue) \(id)") }
      case let .attempt(session, .delta(_, event)): heard.withLock { $0.append("delta \(session.rawValue) \(event.partialMessage.content.count)") }
      case let .attempt(_, .finished(_, outcome)): heard.withLock { $0.append("finished \(outcome)") }
      case let .usage(provider, plan, windows, at): heard.withLock { $0.append("usage \(provider) \(plan ?? "-") \(windows.map(\.name)) \(at)") }
      }
    }
    let notices = WorkerNotices()
    let attempt = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    notices.send(.attempt(session: SessionID("a"), event: .started(attemptID: attempt)))
    notices.send(.attempt(session: SessionID("a"), event: .delta(attemptID: attempt, event: .textDelta(contentIndex: 0, delta: "hi", partial: AssistantMessage(content: [.text(.init(text: "hi"))])))))
    notices.send(.usage(provider: "codex", plan: "pro", windows: [UsageWindow(name: "five_hour", usedPercent: 12, resetsAt: 99)], at: 5))
    notices.send(.attempt(session: SessionID("a"), event: .finished(attemptID: attempt, outcome: .failed(reason: "gone"))))
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask { await client.run() }
      group.addTask { await serveWorkerLine(Recorder(), on: other, notices: notices) }
      while heard.withLock({ $0.count }) < 4 { await Task.yield() }
      main.close()
      try await group.waitForAll()
    }
    #expect(heard.withLock { $0 } == [
      "started a \(attempt)", "delta a 1", "usage codex pro [\"five_hour\"] 5.0", "finished failed(reason: \"gone\")",
    ])
  }
}

@Suite struct WorkerNoticeLineTests {
  // A worker opens its line again after main reboots: the notices sent from
  // then on go down the new line, the old line's gone with it.
  @Test func aLineOpenedAgainCarriesTheNoticesSentAfterIt() async throws {
    let notices = WorkerNotices()
    for round in 1 ... 2 {
      let (main, other) = InMemoryTransport.pair()
      let heard = Mutex<[String]>([])
      let client = WorkerClient(transport: main) { notice in
        if case let .usage(provider, _, _, _) = notice { heard.withLock { $0.append(provider) } }
      }
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await client.run() }
        group.addTask { await serveWorkerLine(Recorder(), on: other, notices: notices) }
        notices.send(.usage(provider: "round \(round)", plan: nil, windows: [], at: 0))
        while heard.withLock({ $0.isEmpty }) { await Task.yield() }
        main.close()
        try await group.waitForAll()
      }
      #expect(heard.withLock { $0 } == ["round \(round)"])
    }
  }
}
