#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import ExecutionOwner
import Fetch
import InferenceKit
import JSONValue
import SessionDomain
import SessionTools
import SpaceContract
import SpaceCore
import Synchronization
import Testing
@testable import WorkerOwner
import WorkerProtocol
import WuhuAI

@Suite(.timeLimit(.minutes(1))) struct RuntimeOwnerTests {
  @Test func attemptsUsageWarmingAndDetachedLossAreParentEffects() async throws {
    let space = try Space.inMemory()
    let session = try await space.sessions.createSession(group: .shared, title: "runtime", kind: .agent, createdBy: "owner", model: .init(provider: "offline", model: "small", effort: "none"))
    let attempts = AttemptHub()
    let events = attempts.events(session: session)
    let lost = Mutex<[String]>([])
    let warming = Mutex<[Int]>([])
    let reminders = Mutex<[Date?]>([])
    let usage = ProviderUsage(plan: "fixture", windows: [.init(name: "five_hour", usedPercent: 37, resetsAt: 500)], observedAt: 100)
    let publications = Mutex<[ProviderUsage]>([])
    var runtime = WorkerRuntimeOwner(attempts: attempts, scriptLost: { caller, script in
      #expect(caller == session)
      lost.withLock { $0.append(script) }
    }, usage: { ["offline": usage] }, receiveUsage: { provider, value in
      #expect(provider == "offline")
      publications.withLock { $0.append(value) }
    }, allowsWarming: { $0 == session }, scheduleReminder: { caller, due in
      #expect(caller == session)
      reminders.withLock { $0.append(due) }
    }, scheduleWarming: { caller, interval in
      #expect(caller == session)
      warming.withLock { $0.append(interval) }
    })
    runtime.scriptEnded = { caller, script in
      #expect(caller == session)
      lost.withLock { $0.append("ended:" + script) }
    }
    let attempt = UUID()
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space), runtime: runtime) { _, remote in
      #expect(try await remote.runtimeUsage()["offline"] == usage)
      try await remote.recordRuntimeUsage("offline", usage: usage)
      #expect(try await remote.allowsCacheWarming(session))
      try await remote.scheduleCacheWarming(session, intervalSeconds: 300)
      try await remote.scheduleReminder(session, at: Date(timeIntervalSince1970: 123))
      try await remote.scheduleReminder(session, at: nil)
      let _: Bool = try await remote.rpc.call("runtime.script-started", ScriptActivity(session: session, script: "detached"))
      try await remote.attemptEvents.publish(session: session, .started(attemptID: attempt))
      try await remote.attemptEvents.publish(session: session, .delta(attemptID: attempt, event: .start(AssistantMessage())))
      #expect(attempts.inFlight(session: session)[attempt] != nil)
    }
    #expect(attempts.inFlight(session: session).isEmpty)
    #expect(publications.withLock { $0 } == [usage])
    #expect(warming.withLock { $0 } == [300])
    #expect(reminders.withLock { $0 } == [Date(timeIntervalSince1970: 123), nil])
    #expect(lost.withLock { $0 } == ["detached", "ended:detached"])
    var iterator = events.makeAsyncIterator()
    guard case .started? = await iterator.next(), case .delta? = await iterator.next(), case let .finished(id, .failed(reason))? = await iterator.next() else { Issue.record("Attempt ordering or terminal loss event is missing"); return }
    #expect(id == attempt && reason == "Execution worker exited")
  }

  @Test func olderParentRefusesReminderBeforeSendingAnEffect() async throws {
    let space = try Space.inMemory()
    let current = ExecutionWorkerBootstrap.hello(release: "current")
    let older = WorkerHello(capabilities: current.capabilities.subtracting([ExecutionWorkerBootstrap.remindersCapability]), required: current.required, release: "older")
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space), hello: older) { _, remote in
      let expected = WorkerProtocolError(.missingCapability, message: "Missing execution capability: " + ExecutionWorkerBootstrap.remindersCapability)
      await #expect(throws: expected) { try await remote.scheduleReminder(.init("task"), at: Date()) }
      await #expect(throws: expected) { try await remote.scheduleReminder(.init("task"), at: nil) }
    }
  }

  @Test func scriptDirectoryCallbacksAndCrossWorkerStopAreRecordedParentEffects() async throws {
    let space = try Space.inMemory()
    let effects = Mutex<[String]>([])
    let session = SessionID("owner")
    var runtime = WorkerRuntimeOwner(attempts: .init(), usage: { [:] }, receiveUsage: { _, _ in }, allowsWarming: { _ in false }, scheduleWarming: { _, _ in })
    runtime.scriptStarted = { caller, script in
      #expect(caller == session)
      effects.withLock { $0.append("started:" + script) }
    }
    runtime.scriptEnded = { caller, script in
      #expect(caller == session)
      effects.withLock { $0.append("ended:" + script) }
    }
    runtime.stopScript = { caller, script in
      #expect(caller == session)
      effects.withLock { $0.append("stop:" + script) }
      return .script(.init(output: "script stopped"))
    }
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space), runtime: runtime) { _, remote in
      let _: Bool = try await remote.rpc.call("runtime.script-started", ScriptActivity(session: session, script: "script"))
      let output = try await remote.stopRuntimeScript(session, script: "script")
      #expect(output == .script(.init(output: "script stopped")))
      let _: Bool = try await remote.rpc.call("runtime.script-ended", ScriptActivity(session: session, script: "script"))
    }
    #expect(effects.withLock { $0 } == ["started:script", "stop:script", "ended:script"])
  }

  @Test func olderPeerRefusesAssignmentAndScriptHandoffBeforeSendingAnEffect() async throws {
    let space = try Space.inMemory()
    let current = ExecutionWorkerBootstrap.hello(release: "current")
    let older = WorkerHello(capabilities: current.capabilities.subtracting([ExecutionWorkerBootstrap.handoffCapability]), required: current.required, release: "older")
    try await withOwnerRPC(owner: InProcessExecutionOwnerClient(space: space), hello: older) { client, remote in
      let expected = WorkerProtocolError(.missingCapability, message: "Missing execution capability: " + ExecutionWorkerBootstrap.handoffCapability)
      await #expect(throws: expected) { try await RemoteSessionExecution(client: client).yieldAssignment(.init("owner")) }
      await #expect(throws: expected) { try await WorkerScriptControl(client: client).stop("script", session: .init("owner")) }
      await #expect(throws: expected) { try await remote.stopRuntimeScript(.init("owner"), script: "script") }
    }
  }
}
