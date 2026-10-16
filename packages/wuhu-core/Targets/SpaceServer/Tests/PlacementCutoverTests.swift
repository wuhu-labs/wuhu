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
import JSONValue
import ServeNIO
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import WorkerProtocol

@Suite(.serialized, .sessionFixtures(timeLimit: .minutes(2))) struct PlacementCutoverTests {
  @Test func quiescedProductionBinaryRestartIntoDefaultWorkerPreservesDurableWorkAndRecoversWorkerCrash() async throws {
    try await withSessionDeps {
      let requests = Mutex<[String: [String]]>([:])
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        let text = try await request.body?.json(JSONValue.self).jsonString() ?? ""
        let marker = text.contains("after-cutover") ? "after-cutover" : text.contains("before-cutover") ? "before-cutover" : "recovery"
        let round = requests.withLock { $0[marker, default: []].append(text); return $0[marker]!.count }
        let source = marker == "recovery" || round != 1 ? nil : "import {writeText} from 'wuhu:space'; await writeText('/\(marker).txt','committed',{ifMatch:null}); result('script effect committed')"
        return cutoverReply(source: source)
      })
      let fixture = try await PlacementCutoverFixture.make(providerPort: #require(provider.localAddress?.port))
      defer { fixture.files.clean() }
      let space = fixture.space
      let before = try await fixture.session("before-cutover")
      try await fixture.enqueue(before, "before-cutover")
      let parent = try await fixture.session("park parent")
      let parked = try await fixture.session("parked task", kind: .task, parent: parent)
      let future = Date().addingTimeInterval(3600)
      _ = try await space.sessions.openRequest(on: parked, from: parent, messageID: .init("parked-request"), text: "waiting for external work", deadline: future)
      _ = try await space.sessions.drainQueue(parked)
      for _ in 0 ..< 3 {
        _ = try await space.sessions.enqueue(parked, input: .notification(.init(id: UUID(), timestamp: Date(), kind: .parkReminder, subscriptionID: .park(.init("parked-request")), requestID: .init("parked-request"), content: .init(text: "park reminder already consumed"))))
      }
      _ = try await space.sessions.drainQueue(parked)
      try await space.sessions.appendAssistant(parked, attemptID: UUID(), message: .init(content: [.text("parked awaiting external work")]), metadata: .init(usage: .init(inputTokens: 1, outputTokens: 1, totalTokens: 2)))
      _ = try await space.sessions.armSubscription(parked, slot: .init(id: .park(.init("parked-request")), kind: .parkReminder(request: .init("parked-request"))), nextFireAt: future)
      _ = try await space.sessions.armSubscription(parked, slot: .init(id: .init("reminder"), kind: .timer(.oneShot(future), message: "durable reminder")), nextFireAt: future)
      try await fixture.write("/observe.js", "export default async ({state}) => ({firings:(state?.firings??0)+1})")
      _ = try await space.sessions.armSubscription(parked, slot: .init(id: .init("observation"), kind: .observe(sql: "SELECT 7 AS value", throttleSeconds: 0), handler: "/observe.js"))
      let outcome: Result<Void, any Error>
      do {
        try await fixture.serve("in-process") { _ in
          try await until("in-process script and observation committed", timeout: .seconds(30)) {
            guard try await fixture.completed(before) else { return false }
            return try await space.sessions.armedSubscriptions(parked).contains { $0.slot.handlerStateJSON == "{\"firings\":1}" }
          }
          #expect(try await fixture.worker() == nil)
          #expect(try await space.sessions.record(parked).work == .noWork)
        }
        let committed = try await space.fs(.shared).stat("/before-cutover.txt")
        let parkedState = try await space.sessions.settleState(parked)
        let parkedSubscriptions = try await space.sessions.armedSubscriptions(parked)
        let parentSubscriptions = try await space.sessions.armedSubscriptions(parent)
        let after = try await fixture.session("after-cutover")
        try await fixture.enqueue(after, "after-cutover queued-first")
        try await fixture.enqueue(after, "after-cutover queued-second")
        let handler = try await fixture.session("held worker handler")
        try await fixture.write("/held-worker.js", "import {writeText} from 'wuhu:space'; export default async () => { await writeText('/worker-handler-entered.txt','committed',{ifMatch:null}); await sleep(600000); await writeText('/worker-handler-must-not-finish.txt','no',{ifMatch:null}); return {finished:true}; }")
        let due = Date().addingTimeInterval(-1)
        _ = try await space.sessions.armSubscription(handler, slot: .init(id: .init("held"), kind: .timer(.oneShot(due), message: ""), handler: "/held-worker.js"), nextFireAt: due)
        try await fixture.serve() { _ in
          try await until("worker drains queued input and executes real script/handler", timeout: .seconds(40)) {
            guard try await fixture.completed(after) else { return false }
            return await fixture.exists("/worker-handler-entered.txt")
          }
          #expect(try await space.sessions.hydrate(after).undrained.isEmpty)
          #expect(try await space.fs(.shared).read("/after-cutover.txt").1 == Data("committed".utf8))
          #expect(try await space.fs(.shared).stat("/before-cutover.txt") == committed)
          #expect(try await space.sessions.settleState(parked) == parkedState)
          #expect(try await space.sessions.record(parked).work == .noWork)
          #expect(try await space.sessions.armedSubscriptions(parked) == parkedSubscriptions)
          #expect(try await space.sessions.armedSubscriptions(parent) == parentSubscriptions)
          let body = try #require(requests.withLock { $0["after-cutover"]?.first })
          let first = try #require(body.range(of: "queued-first"))
          let second = try #require(body.range(of: "queued-second"))
          #expect(first.lowerBound < second.lowerBound)
          let oldWorker = try #require(try await fixture.worker())
          #expect(try processBirthIdentity(oldWorker.processID) == oldWorker.birth)
          #expect(kill(oldWorker.processID, SIGKILL) == 0)
          try await until("replacement child drains handler failure", timeout: .seconds(40)) {
            guard let replacement = try await fixture.worker(), replacement.processID != oldWorker.processID else { return false }
            return try await fixture.completed(handler)
          }
          #expect(try await space.sessions.armedSubscriptions(handler).first?.slot.lastError != nil)
          #expect(try await space.sessions.armedSubscriptions(handler).first?.slot.handlerStateJSON == nil)
          #expect(await !fixture.exists("/worker-handler-must-not-finish.txt"))
          #expect(requests.withLock { $0["before-cutover"]?.count } == 2)
          #expect(requests.withLock { $0["after-cutover"]?.count } == 2)
        }
        outcome = .success(())
      } catch { outcome = .failure(error) }
      await provider.shutdown()
      try outcome.get()
    }
  }

  @Test(arguments: [SIGTERM, SIGKILL])
  func unquiescedRestartLosesInProcessMemoryAndRetriesAnUncommittedHandlerFiring(stopSignal: Int32) async throws {
    try await withSessionDeps {
      let requests = Mutex<[String: Int]>([:])
      let gate = AsyncStream<Void>.makeStream()
      let provider = try await ServeNIOServer.bind(port: 0, handler: { request in
        let text = try await request.body?.json(JSONValue.self).jsonString() ?? ""
        let marker = text.contains("old-inference-case") ? "inference" : text.contains("old-script-case") ? "script" : "other"
        let round = requests.withLock { $0[marker, default: 0] += 1; return $0[marker]! }
        if marker == "inference", round == 1 { for await _ in gate.stream { break } }
        let source = marker == "script" && round == 1 ? "import {writeText} from 'wuhu:space'; await writeText('/old-script-entered.txt','committed',{ifMatch:null}); result('detached'); await sleep(600000); await writeText('/old-script-must-not-finish.txt','no',{ifMatch:null})" : nil
        return cutoverReply(source: source)
      })
      let fixture = try await PlacementCutoverFixture.make(providerPort: #require(provider.localAddress?.port))
      defer { fixture.files.clean(); gate.continuation.finish() }
      let inference = try await fixture.session("old inference")
      let script = try await fixture.session("old script")
      let handler = try await fixture.session("old handler")
      try await fixture.enqueue(inference, "old-inference-case")
      try await fixture.enqueue(script, "old-script-case")
      try await fixture.write("/old-handler.js", "import {readText,writeText} from 'wuhu:space'; export default async () => { let prior=false; try { await readText('/old-handler-entered.txt'); prior=true; } catch {} if(prior) { await writeText('/old-handler-retried.txt','new invocation',{ifMatch:null}); return {newInvocation:true}; } await writeText('/old-handler-entered.txt','committed',{ifMatch:null}); await sleep(600000); await writeText('/old-handler-must-not-finish.txt','no',{ifMatch:null}); return {oldInvocation:true}; }")
      let due = Date().addingTimeInterval(-1)
      _ = try await fixture.space.sessions.armSubscription(handler, slot: .init(id: .init("held"), kind: .timer(.oneShot(due), message: ""), handler: "/old-handler.js"), nextFireAt: due)
      let outcome: Result<Void, any Error>
      do {
        try await fixture.serve("in-process", stopSignal: stopSignal) { _ in
          try await until("old inference, detached script and handler are simultaneously live", timeout: .seconds(40)) {
            guard requests.withLock({ $0["inference"] == 1 }), try await fixture.completed(script), await fixture.exists("/old-script-entered.txt") else { return false }
            return await fixture.exists("/old-handler-entered.txt")
          }
          #expect(try await fixture.worker() == nil)
          #expect(try await fixture.space.sessions.armedSubscriptions(handler).first?.slot.handlerStateJSON == nil)
          #expect(try await !fixture.completed(inference))
        }
        gate.continuation.finish()
        let scriptEffect = try await fixture.space.fs(.shared).stat("/old-script-entered.txt")
        let handlerEffect = try await fixture.space.fs(.shared).stat("/old-handler-entered.txt")
        try await fixture.serve() { _ in
          try await until("new inference attempt and new handler invocation finish", timeout: .seconds(40)) {
            guard try await fixture.completed(inference), await fixture.exists("/old-handler-retried.txt") else { return false }
            return try await fixture.space.sessions.armedSubscriptions(handler).isEmpty
          }
          #expect(try await fixture.worker() != nil)
          #expect(requests.withLock { $0["inference"] } == 2)
          #expect(requests.withLock { $0["script", default: 0] } >= 2)
          #expect(try await fixture.space.fs(.shared).stat("/old-script-entered.txt") == scriptEffect)
          #expect(try await fixture.space.fs(.shared).stat("/old-handler-entered.txt") == handlerEffect)
          #expect(await !fixture.exists("/old-script-must-not-finish.txt"))
          #expect(await !fixture.exists("/old-handler-must-not-finish.txt"))
        }
        outcome = .success(())
      } catch { outcome = .failure(error) }
      gate.continuation.finish()
      await provider.shutdown()
      try outcome.get()
    }
  }
}
