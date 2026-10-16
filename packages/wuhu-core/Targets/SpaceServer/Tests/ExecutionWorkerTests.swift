#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Credentials
import Dependencies
import ExecutionOwner
import Fetch
import GRDB
import InferenceKit
import LoopCore
import ServeNIO
import ServerTelemetry
import SessionDomain
import SessionTools
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WorkerOwner
import WorkerProtocol

private let workerSSE = """
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":10}}}

event: content_block_start
data: {"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"delta":{"type":"text_delta","text":"Answered by the execution worker"}}

event: content_block_stop
data: {"index":0}

event: message_delta
data: {"delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

event: message_stop
data: {}

"""

@Suite(.sessionFixtures(timeLimit: .minutes(2))) struct ExecutionWorkerTests {
  private func binary() throws -> String {
    let path = try #require(ProcessInfo.processInfo.environment["WUHU_EXECUTION_WORKER_BINARY"])
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private func models(_ space: Space, port: Int) async throws {
    let json = """
    {"offline":{"dialect":"anthropic","baseURL":"http://127.0.0.1:\(port)","opaqueReplay":"none","models":{"small":{"maxInput":100000,"maxOutput":1000,"efforts":["none"],"defaultEffort":"none"}}}}
    """
    _ = try await space.fs(.shared).write("/models.json", Data(json.utf8), ifMatch: nil)
  }

  private func input(_ text: String) -> QueueInput {
    .notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init(rawValue: "fixture"), content: .init(text: text)))
  }

  @Test(arguments: [false, true]) func workerAssemblyRunsInferenceInSameBinaryChildAndCommitsThroughParent(tracing: Bool) async throws {
    let spans = Mutex<[FinishedSpan]>([])
    let emit: @Sendable (FinishedSpan) -> Void = { span in spans.withLock { $0.append(span) } }
    try await ServerTracing.$emitter.withValue(tracing ? emit : nil) {
      try await withSessionDeps {
        let requests = Mutex(0)
        let metrics = Mutex<[InferenceMetric]>([])
        let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
          #expect(request.headers[.init("x-api-key")!] == "fixture-credential")
          _ = try await request.body?.data()
          requests.withLock { $0 += 1 }
          return Response(status: .ok, body: .bytes(Data(workerSSE.utf8), contentType: "text/event-stream"))
        })
        let space = try Space.inMemory()
        try await models(space, port: #require(provider.localAddress?.port))
        let runtime = await SessionRuntime.assemble(
          space: space, hub: MachineHub(space: space), attemptLog: nil,
          metrics: InferenceMetricsSink { metric in metrics.withLock { $0.append(metric) } },
          credentials: CredentialResolver { _ in .apiKey("fixture-credential") }, secrets: nil,
          usage: UsageBoard(), executionPlacement: .worker(executable: URL(fileURLWithPath: try binary())),
        )
        let result: Result<Void, any Error>
        do {
          let id = try await space.sessions.createSession(group: .shared, title: "worker", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
          #expect(requests.withLock { $0 } == 0)
          _ = try await runtime.service.enqueue(item: input("hello"), to: id)
          try await until("worker inference commits", timeout: .seconds(40)) { try await space.sessions.transcript(id).items.contains { if case .assistant = $0 { true } else { false } } }
          let transcript = try await space.sessions.transcript(id)
          #expect(transcript.items.contains { if case let .assistant(entry) = $0 { entry.content.contains(.text("Answered by the execution worker")) } else { false } })
          #expect(requests.withLock { $0 } == 1)
          #expect(metrics.withLock { $0.first?.session } == id)
          #expect(metrics.withLock { $0.first?.outcome } == .ok)
          try await runtime.service.interrupt(id)
          #expect(try await space.sessions.record(id).hold == .interrupted)
          try await runtime.service.resume(id)
          #expect(try await space.sessions.record(id).hold == .normal)
          let restarted = try await runtime.service.restart(id, executor: nil, note: nil)
          #expect(restarted.generation == 1)
          try await runtime.service.archive(id)
          if case .archived = try await space.sessions.record(id).lifecycle {} else { Issue.record("remote archive did not persist") }
          try await runtime.service.unarchive(id)
          #expect(try await space.sessions.record(id).lifecycle == .live)
          result = .success(())
        } catch { result = .failure(error) }
        await runtime.service.shutdown()
        await provider.shutdown()
        try result.get()
        let relayed = spans.withLock { $0 }
        if tracing {
          #expect(relayed.contains { $0.name == .turn && $0.context.group == "shared" && !$0.context.session.isEmpty })
          let encoded = String(decoding: try JSONEncoder().encode(relayed), as: UTF8.self)
          #expect(!encoded.contains("fixture-credential"))
          #expect(!encoded.contains("Answered by the execution worker"))
        } else {
          #expect(relayed.isEmpty)
        }
      }
    }
  }

  @Test func workerPublishesParkDeadlineToTheParentInsteadOfKeepingATimer() async throws {
    try await withSessionDeps {
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        _ = try await request.body?.data()
        return Response(status: .ok, body: .bytes(Data(workerSSE.utf8), contentType: "text/event-stream"))
      })
      let space = try Space.inMemory()
      try await models(space, port: #require(provider.localAddress?.port))
      let deadlines = Mutex<[Date?]>([])
      let owner = InProcessExecutionOwnerClient(space: space, credentials: CredentialResolver { _ in .apiKey("fixture-credential") })
      let runtime = workerRuntimeFixture(space: space, scheduleReminder: { _, due in deadlines.withLock { $0.append(due) } })
      let worker = LazyExecutionWorker(executable: try binary(), sessions: space.sessions, owner: owner, spawn: { _, _, _ in throw CancellationError() }, runtime: runtime)
      let service = SessionService(sessions: space.sessions, execution: worker, archiveGrace: .seconds(60))
      let result: Result<Void, any Error>
      do {
        let id = try await space.sessions.createSession(group: .shared, title: "parked", kind: .task, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
        let request = QueueInput.message(.init(id: UUID(), messageID: .init("request"), conversationID: .init("dm"), sender: Sender(id: "owner", timeZone: TimeZone(secondsFromGMT: 0)!), timestamp: Date(), kind: .request, requestID: .init("request"), content: .init(text: "work")))
        _ = try await service.enqueue(item: request, to: id)
        try await until("worker delegates the park deadline", timeout: .seconds(40)) { deadlines.withLock { $0.contains { $0 != nil } } }
        #expect(deadlines.withLock { $0.compactMap { $0 }.count } == 1)
        let transcript = try await space.sessions.transcript(id)
        let parks = transcript.items.compactMap { item -> SystemNotification? in
          guard case let .notification(notice) = item, notice.kind == .parkReminder else { return nil }
          return notice
        }
        let due = try #require(deadlines.withLock { $0.compactMap { $0 }.first })
        let remindedAt = try #require(parks.last).timestamp
        #expect(abs(due.timeIntervalSince(remindedAt) - 60) < 0.1)
        await worker.discard(id)
        #expect(deadlines.withLock { $0.compactMap { $0 }.count } == 1)
        result = .success(())
      } catch { result = .failure(error) }
      await service.shutdown()
      await provider.shutdown()
      try result.get()
    }
  }

  enum RecoveryFault: Sendable { case none, replacementAdmission, cleanupOnce, cleanupAlways }

  @Test(arguments: [RecoveryFault.none, .replacementAdmission, .cleanupOnce, .cleanupAlways])
  func lazyWorkerReusesOneChildAndCrashImmediatelyResumesPersistedWork(fault: RecoveryFault) async throws {
    try await withSessionDeps {
      let requests = Mutex(0)
      let entered = AsyncStream<Void>.makeStream()
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        _ = try await request.body?.data()
        let index = requests.withLock { value in value += 1; return value }
        if index == 1 {
          entered.continuation.yield(())
          let (parking, continuation) = AsyncStream<Void>.makeStream()
          for await _ in parking {}
          continuation.finish()
          throw CancellationError()
        }
        return Response(status: .ok, body: .bytes(Data(workerSSE.utf8), contentType: "text/event-stream"))
      })
      let space = try Space.inMemory()
      try await models(space, port: #require(provider.localAddress?.port))
      let owner = InProcessExecutionOwnerClient(space: space, credentials: CredentialResolver { _ in .apiKey("fixture-credential") })
      let starts = Mutex(0)
      let cleanupWrites = Mutex(0)
      let executable = try binary()
      let worker = LazyExecutionWorker(executable: executable, sessions: space.sessions, owner: owner, spawn: { _, _, _ in throw CancellationError() }, startConnection: { _, activity, exited in
        let attempt = starts.withLock { $0 += 1; return $0 }
        if fault == .replacementAdmission, attempt == 2 { throw WorkerProtocolError(.unavailable, message: "one replacement admission failure") }
        if attempt > 1, fault == .cleanupOnce { #expect(cleanupWrites.withLock { $0 } == 2) }
        return try await WorkerConnection.start(executable: executable, owner: owner, spawn: { _, _, _ in throw CancellationError() }, runtime: workerRuntimeFixture(space: space), activity: activity, exited: exited)
      })
      let service = SessionService(sessions: space.sessions, execution: worker, archiveGrace: .seconds(60))
      #expect(await worker.processID == nil)
      let result: Result<Void, any Error>
      do {
        let broken = try await space.sessions.createSession(group: .shared, title: "broken earlier session", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
        let brokenItem = TranscriptItem.notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("broken"), content: .init(text: "corrupt history")))
        var brokenTranscript = try await space.sessions.transcript(broken)
        brokenTranscript.append(brokenItem)
        try await owner.append(broken, items: [brokenItem], transcript: brokenTranscript, completingCompactRequest: nil)
        try await space.writer.write { db in
          try db.execute(sql: "UPDATE session_contents SET payload = '{}' WHERE session_id = ?", arguments: [broken.rawValue])
        }
        _ = try await space.sessions.enqueue(broken, input: input("pending broken work"))
        let first = try await space.sessions.createSession(group: .shared, title: "first", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
        _ = try await service.enqueue(item: input("hang"), to: first)
        for await _ in entered.stream { break }
        let firstPID = try #require(await worker.processID)
        #expect(firstPID != getpid())
        try await service.wake(first)
        #expect(await worker.processID == firstPID)
        let callID = ToolCallID("lost-effect")
        var persisted = try await space.sessions.transcript(first)
        let assistant = TranscriptItem.assistant(.init(id: UUID(), timestamp: Date(), content: [.toolCall(.init(id: callID.rawValue, name: "write", arguments: .object(["path": .string("/must-not-replay"), "content": .string("effect")])))], stopReason: .stop, usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2), toolCallIDs: [:]))
        persisted.append(assistant)
        try await owner.append(first, items: [assistant], transcript: persisted, completingCompactRequest: nil)
        if fault == .cleanupOnce || fault == .cleanupAlways {
          try await space.writer.write { db in
            db.add(function: DatabaseFunction("worker_cleanup_fault", argumentCount: 0) { _ in
              let attempt = cleanupWrites.withLock { $0 += 1; return $0 }
              if attempt == 1 || fault == .cleanupAlways { throw WorkerProtocolError(.unavailable, message: "fixture cleanup write failure") }
              return nil
            })
            try db.execute(sql: "CREATE TEMP TRIGGER worker_cleanup_fault BEFORE INSERT ON session_contents WHEN NEW.payload LIKE '%executionWorkerRestart%' BEGIN SELECT worker_cleanup_fault(); END")
          }
        }
        #expect(kill(firstPID, SIGKILL) == 0)
        if fault == .cleanupAlways {
          try await until("failed cleanup durably fences execution", timeout: .seconds(20)) { try await space.sessions.record(first).work == .errored }
          #expect(try await space.sessions.record(first).errorMessage?.hasPrefix("executionWorkerRecoveryFailed:") == true)
          #expect(cleanupWrites.withLock { $0 } == 3)
          #expect(await worker.activeSessions.contains(first) == false)
          #expect(requests.withLock { $0 } == 1)
          await #expect(throws: SessionExecutionRetired.self) { try await worker.wake(first) }
        } else {
          try await until("fresh worker resumes persisted inference", timeout: .seconds(40)) { try await space.sessions.transcript(first).items.contains { if case let .assistant(entry) = $0 { entry.content.contains(.text("Answered by the execution worker")) } else { false } } }
          #expect(await worker.processID != firstPID)
          #expect(requests.withLock { $0 } == 2)
          #expect(try await space.sessions.record(first).work != .errored)
          let recovered = try await space.sessions.transcript(first)
          #expect(recovered.pendingToolCallIDs.isEmpty)
          #expect(recovered.items.contains { item in
            guard case let .toolResult(result) = item, result.provenance == .toolCall(callID), case let .failure(failure) = result.payload else { return false }
            return failure.code == "executionWorkerRestart"
          })
          let results = recovered.items.filter { if case let .toolResult(result) = $0 { result.provenance == .toolCall(callID) } else { false } }
          #expect(results.count == 1)
          #expect(starts.withLock { $0 } == (fault == .replacementAdmission ? 3 : 2))
          if fault == .cleanupOnce { #expect(cleanupWrites.withLock { $0 } == 2) }
        }
        await #expect(throws: (any Error).self) { try await space.fs(.shared).stat("/must-not-replay") }
        result = .success(())
      } catch { result = .failure(error) }
      entered.continuation.finish()
      await service.shutdown()
      await provider.shutdown()
      try result.get()
    }
  }

  @Test func idleWorkerLossStillBootsPendingWorkWithoutChargingIdleSessions() async throws {
    try await withSessionDeps {
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        _ = try await request.body?.data()
        return Response(status: .ok, body: .bytes(Data(workerSSE.utf8), contentType: "text/event-stream"))
      })
      let space = try Space.inMemory()
      try await models(space, port: #require(provider.localAddress?.port))
      let owner = InProcessExecutionOwnerClient(space: space, credentials: CredentialResolver { _ in .apiKey("fixture-credential") })
      let worker = LazyExecutionWorker(executable: try binary(), sessions: space.sessions, owner: owner, spawn: { _, _, _ in throw CancellationError() }, runtime: workerRuntimeFixture(space: space))
      let service = SessionService(sessions: space.sessions, execution: worker, archiveGrace: .seconds(60))
      let result: Result<Void, any Error>
      do {
        let idle = try await space.sessions.createSession(group: .shared, title: "idle", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
        _ = try await service.enqueue(item: input("settle"), to: idle)
        try await until("first worker settles", timeout: .seconds(40)) {
          let settled = try await space.sessions.record(idle).work == .noWork
          let active = await worker.activeSessions
          return settled && active.isEmpty
        }
        let pending = try await space.sessions.createSession(group: .shared, title: "pending", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
        _ = try await space.sessions.enqueue(pending, input: input("not dispatched yet"))
        let pid = try #require(await worker.processID)
        #expect(kill(pid, SIGKILL) == 0)
        try await until("idle loss boots pending inventory", timeout: .seconds(40)) { try await space.sessions.transcript(pending).items.contains { if case .assistant = $0 { true } else { false } } }
        #expect(await worker.processID != pid)
        #expect(try await space.sessions.workerCrashFenced(idle) == false)
        result = .success(())
      } catch { result = .failure(error) }
      await service.shutdown()
      await provider.shutdown()
      try result.get()
    }
  }

  @Test func threeWorkerDeathsFenceOneSessionWithoutRewakingIt() async throws {
    try await withSessionDeps {
      let requests = Mutex(0)
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        _ = try await request.body?.data()
        requests.withLock { $0 += 1 }
        let (parking, continuation) = AsyncStream<Void>.makeStream()
        for await _ in parking {}
        continuation.finish()
        throw CancellationError()
      })
      let space = try Space.inMemory()
      try await models(space, port: #require(provider.localAddress?.port))
      let owner = InProcessExecutionOwnerClient(space: space, credentials: CredentialResolver { _ in .apiKey("fixture-credential") })
      let worker = LazyExecutionWorker(executable: try binary(), sessions: space.sessions, owner: owner, spawn: { _, _, _ in throw WorkerProtocolError(.invalidMessage, message: "Unused test spawn") }, runtime: workerRuntimeFixture(space: space))
      let service = SessionService(sessions: space.sessions, execution: worker, archiveGrace: .seconds(60))
      let result: Result<Void, any Error>
      do {
        let id = try await space.sessions.createSession(group: .shared, title: "crash loop", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
        _ = try await service.enqueue(item: input("hang"), to: id)
        var pids: Set<Int32> = []
        for count in 1 ... 3 {
          try await until("incarnation enters inference", timeout: .seconds(40)) { requests.withLock { $0 } == count }
          let pid = try #require(await worker.processID)
          let freshPID = pids.insert(pid).inserted
          #expect(freshPID)
          #expect(kill(pid, SIGKILL) == 0)
        }
        try await until("third crash fences session", timeout: .seconds(20)) { try await space.sessions.record(id).work == .errored }
        let record = try await space.sessions.record(id)
        #expect(record.errorMessage == ExecutionWorkerCrashLoop(session: id).description)
        try await service.wake(id)
        #expect(await worker.processID == nil)
        #expect(requests.withLock { $0 } == 3)
        result = .success(())
      } catch { result = .failure(error) }
      await service.shutdown()
      await provider.shutdown()
      try result.get()
    }
  }
}

private func workerRuntimeFixture(space: Space, attempts: AttemptHub = .init(), scheduleReminder: @escaping @Sendable (SessionID, Date?) async throws -> Void = { _, _ in }) -> WorkerRuntimeOwner {
  .init(attempts: attempts, usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleReminder: scheduleReminder, scheduleWarming: { session, interval in
    try await space.sessions.scheduleCacheWarming(session, intervalSeconds: interval)
  })
}
