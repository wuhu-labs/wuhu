import ControlledTime
import Dependencies
import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import Scratch
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct PushRolloverTests {
  enum Transport: CaseIterable, Sendable {
    case webPush
    case pushRelay

    var params: NotificationDeliveryJob.Params {
      switch self { case .webPush: .webPush; case .pushRelay: .pushRelay }
    }

    var key: String {
      switch self { case .webPush: "web-push"; case .pushRelay: "push-relay" }
    }
  }

  @Test(arguments: Transport.allCases)
  func aDrainedJobContinuesOnTheNewWorkerWithoutReplayingItsCursor(_ transport: Transport) async throws {
    try await withDependencies {
      $0.installTimeControl(anchor: fixedDate)
    } operation: {
      @Dependency(\.timeControl) var time
      let folder = try ScratchFolder("push-rollover")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      try await closing([old, new]) {
        _ = old.worker
        _ = new.worker
        let owner: SessionID
        switch transport {
        case .webPush: owner = try await notificationSpace(endpoints: ["https://push.example/live"], space: old).owner
        case .pushRelay: owner = try await relaySpace(grants: ["g1_live"], space: old).owner
        }
        let sent = PushSent()
        try install(old, transport: transport, sent: sent)
        old.worker.start()
        try await outboxEventually("the first notification commits") {
          let pending = try await due(old, transport)
          return sent.values.withLock { $0.count == 1 } && pending.isEmpty
        }
        try install(new, transport: transport, sent: sent)
        new.worker.start()
        try await time.wake("the new worker's scan", after: 1)
        #expect(sent.values.withLock { $0 } == ["answer"])

        await old.stopWorker()
        _ = try await new.sessions.post(
          .box(owner), messageID: MessageID("after-drain"),
          sender: Sender(id: "other", timeZone: TimeZone(identifier: "UTC")!),
          replyTarget: MessageID("question"), content: .init(text: "after drain"),
        )
        try await new.sessions.inboxesSettled()
        // The commit's poke may already have claimed the job on the new worker and sent this one, or it may still be due: either way only the new notification, never the one before the drain.
        #expect(try await due(new, transport).allSatisfy { $0 == 2 })
        try await time.wake("the new worker claims the released job", after: 1)
        try await outboxEventually("the successor sends the new notification") {
          await time.advance(to: Date(timeIntervalSince1970: Double(new.worker.scheduler.now.milliseconds) / 1000 + 1))
          let pending = try await due(new, transport)
          return sent.values.withLock { $0.count == 2 } && pending.isEmpty
        }
        #expect(sent.values.withLock { $0 } == ["answer", "after drain"])
      }
    }
  }

  @Test(arguments: Transport.allCases)
  func notificationMailWakesTheWaitingTransportWithoutAdvancingTime(_ transport: Transport) async throws {
    try await withDependencies {
      $0.installTimeControl(anchor: fixedDate)
    } operation: {
      @Dependency(\.timeControl) var time
      let space = try Space.inMemory()
      try await closing([space]) {
        _ = space.worker
        let owner: SessionID
        switch transport {
        case .webPush: owner = try await notificationSpace(endpoints: ["https://push.example/live"], space: space).owner
        case .pushRelay: owner = try await relaySpace(grants: ["g1_live"], space: space).owner
        }
        let sent = PushSent()
        try install(space, transport: transport, sent: sent)
        space.worker.start()
        try await outboxEventually("the first notification commits") {
          let pending = try await due(space, transport)
          return sent.values.withLock { $0.count == 1 } && pending.isEmpty
        }
        try await time.asleep("the transport waits for mail", dueIn: 15)
        let before = space.worker.scheduler.now
        _ = try await space.sessions.post(
          .box(owner), messageID: MessageID("mail-wakeup"),
          sender: Sender(id: "other", timeZone: TimeZone(identifier: "UTC")!),
          replyTarget: MessageID("question"), content: .init(text: "mail woke me"),
        )
        try await space.sessions.inboxesSettled()
        try await outboxEventually("mail wakes the waiting transport") {
          let pending = try await due(space, transport)
          return sent.values.withLock { $0.count == 2 } && pending.isEmpty
        }
        #expect(space.worker.scheduler.now == before)
        #expect(sent.values.withLock { $0 } == ["answer", "mail woke me"])
      }
    }
  }

  @Test(arguments: Transport.allCases)
  func oneScanFindsNotificationsWrittenThroughAnotherSpace(_ transport: Transport) async throws {
    try await withDependencies {
      $0.installTimeControl(anchor: fixedDate)
    } operation: {
      @Dependency(\.timeControl) var time
      let folder = try ScratchFolder("push-poll")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let other = try Space.open(file: file)
      try await closing([old, other]) {
        _ = old.worker
        let owner: SessionID
        switch transport {
        case .webPush: owner = try await notificationSpace(endpoints: ["https://push.example/live"], space: old).owner
        case .pushRelay: owner = try await relaySpace(grants: ["g1_live"], space: old).owner
        }
        let sent = PushSent()
        try install(old, transport: transport, sent: sent)
        old.worker.start()
        try await outboxEventually("the first notification commits") {
          let pending = try await due(old, transport)
          return sent.values.withLock { $0.count == 1 } && pending.isEmpty
        }
        try await time.asleep("the transport poll", dueIn: 15)
        let recipient = try await old.sessions.record(owner).createdBy
        let another = try await old.sessions.createSession(group: .shared, title: "another", kind: .agent, createdBy: recipient, model: .init(provider: "testing", model: "test-model", effort: "medium"))
        try await old.sessions.markInterrupted(another)
        _ = try await other.sessions.post(
          .box(another), messageID: MessageID("another-question"),
          sender: Sender(id: recipient, timeZone: TimeZone(identifier: "UTC")!), content: .init(text: "question"),
        )
        _ = try await other.sessions.post(
          .box(another), messageID: MessageID("cross-process"),
          sender: Sender(id: "other", timeZone: TimeZone(identifier: "UTC")!),
          content: .init(text: "another process"),
        )
        try await time.wake("the scan delivers notification mail", after: 1)
        try await old.sessions.inboxesSettled()
        try await outboxEventually("durable mail sends the other process's notification") {
          let pending = try await due(old, transport)
          return sent.values.withLock { $0.count == 2 } && pending.isEmpty
        }
        #expect(sent.values.withLock { $0 } == ["answer", "another process"])
      }
    }
  }

  @Test(arguments: Transport.allCases)
  func retriesUseTheInjectedPollClock(_ transport: Transport) async throws {
    try await withDependencies {
      $0.installTimeControl(anchor: fixedDate)
    } operation: {
      @Dependency(\.timeControl) var time
      let space = try Space.inMemory()
      try await closing([space]) {
        _ = space.worker
        switch transport {
        case .webPush: _ = try await notificationSpace(endpoints: ["https://push.example/live"], space: space)
        case .pushRelay: _ = try await relaySpace(grants: ["g1_live"], space: space)
        }
        let attempts = PushSent()
        try install(
          space, transport: transport,
          webPush: WebPushClient { message in
            let first = attempts.values.withLock { values in values.append(message.body); return values.count == 1 }
            if first { throw WebPushTransportError(status: 503, retryAfter: "30", underlying: "busy") }
          },
          pushRelay: PushRelayClient { message in
            let first = attempts.values.withLock { values in values.append(message.body); return values.count == 1 }
            if first { throw PushRelayTransportError(status: 503, retryAfter: "30", underlying: "busy") }
          },
        )
        space.worker.start()
        try await outboxEventually("the failed attempt is postponed") {
          let pending = try await due(space, transport)
          return attempts.values.withLock { $0.count == 1 } && pending.isEmpty
        }
        try await time.wake("the first poll", after: 15)
        #expect(attempts.values.withLock { $0.count } == 1)
        await time.advance(to: fixedDate.addingTimeInterval(30))
        try await outboxEventually("the retry commits") {
          await time.advance(to: Date(timeIntervalSince1970: Double(space.worker.scheduler.now.milliseconds) / 1000 + 1))
          let pending = try await due(space, transport)
          return attempts.values.withLock { $0.count == 2 } && pending.isEmpty
        }
        #expect(attempts.values.withLock { $0 } == ["answer", "answer"])
      }
    }
  }

  @Test(arguments: Transport.allCases)
  func cancellingAnInFlightDeliveryDoesNotPostponeIt(_ transport: Transport) async throws {
    try await withDependencies {
      $0.installTimeControl(anchor: fixedDate)
    } operation: {
      @Dependency(\.timeControl) var time
      let folder = try ScratchFolder("push-cancel")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      try await closing([old, new]) {
        _ = old.worker
        _ = new.worker
        switch transport {
        case .webPush: _ = try await notificationSpace(endpoints: ["https://push.example/live"], space: old)
        case .pushRelay: _ = try await relaySpace(grants: ["g1_live"], space: old)
        }
        let entered = Gate()
        let blocked = Gate()
        try install(
          old, transport: transport,
          webPush: WebPushClient { _ in entered.open(); await blocked.wait(); try Task.checkCancellation() },
          pushRelay: PushRelayClient { _ in entered.open(); await blocked.wait(); try Task.checkCancellation() },
        )
        old.worker.start()
        await entered.wait()
        let sent = PushSent()
        try install(new, transport: transport, sent: sent)
        new.worker.start()
        await old.stopWorker()
        #expect(try await due(new, transport).count == 1)
        switch transport {
        case .webPush: #expect(try await new.dueWebPushDeliveries(at: fixedDate).first?.consecutiveFailures == 0)
        case .pushRelay: #expect(try await new.duePushRelayDeliveries(at: fixedDate).first?.consecutiveFailures == 0)
        }
        try await outboxEventually("the cancelled delivery is immediately eligible on its successor") {
          await time.advance(to: Date(timeIntervalSince1970: Double(new.worker.scheduler.now.milliseconds) / 1000 + 1))
          let pending = try await due(new, transport)
          return sent.values.withLock { $0.count == 1 } && pending.isEmpty
        }
        #expect(sent.values.withLock { $0 } == ["answer"])
      }
    }
  }

  @Test(arguments: Transport.allCases)
  func aSuccessfulSendReturningAfterCancellationCommitsBeforeLeaseRelease(_ transport: Transport) async throws {
    try await withDependencies {
      $0.installTimeControl(anchor: fixedDate)
    } operation: {
      @Dependency(\.timeControl) var time
      let folder = try ScratchFolder("push-cancel-success")
      let file = folder.url.appending(path: "space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      try await closing([old, new]) {
        _ = old.worker
        _ = new.worker
        switch transport {
        case .webPush: _ = try await notificationSpace(endpoints: ["https://push.example/live"], space: old)
        case .pushRelay: _ = try await relaySpace(grants: ["g1_live"], space: old)
        }
        let entered = Gate()
        let blocked = Gate()
        let returnedCancelled = Mutex(false)
        let send: @Sendable () async -> Void = {
          entered.open()
          await blocked.wait()
          returnedCancelled.withLock { $0 = Task.isCancelled }
        }
        try install(
          old, transport: transport,
          webPush: WebPushClient { _ in await send() },
          pushRelay: PushRelayClient { _ in await send() },
        )
        old.worker.start()
        await entered.wait()
        let sent = PushSent()
        try install(new, transport: transport, sent: sent)
        new.worker.start()
        await old.stopWorker()
        #expect(returnedCancelled.withLock { $0 })
        #expect(try await due(new, transport).isEmpty)
        try await time.wake("the successor claims the released job", after: 1)
        try await time.asleep("the successor waits without replaying the accepted notification", dueIn: 15)
        #expect(sent.values.withLock { $0.isEmpty })
        #expect(try await due(new, transport).isEmpty)
      }
    }
  }

  private nonisolated(nonsending) func closing(_ spaces: [Space], _ body: () async throws -> Void) async throws {
    do {
      try await body()
    } catch {
      for space in spaces { try await space.close() }
      throw error
    }
    for space in spaces { try await space.close() }
  }

  private func install(_ space: Space, transport: Transport, sent: PushSent) throws {
    try install(
      space, transport: transport,
      webPush: WebPushClient { message in sent.values.withLock { $0.append(message.body) } },
      pushRelay: PushRelayClient { message in sent.values.withLock { $0.append(message.body) } },
    )
  }

  private func install(_ space: Space, transport: Transport, webPush: WebPushClient, pushRelay: PushRelayClient) throws {
    let worker = space.worker
    worker.provide(notificationDeliveryClient(space: space, logger: Logger(label: "push-job-test"), webPush: webPush, pushRelay: pushRelay))
    worker.register(.job(NotificationDeliveryJob.self))
    try worker.create(NotificationDeliveryJob.ID(transport.key), params: transport.params)
  }

  private func due(_ space: Space, _ transport: Transport) async throws -> [Int64] {
    @Dependency(\.date.now) var now
    switch transport {
    case .webPush: return try await space.dueWebPushDeliveries(at: now).map(\.notification.n)
    case .pushRelay: return try await space.duePushRelayDeliveries(at: now).map(\.notification.n)
    }
  }
}

private final class PushSent: Sendable {
  let values = Mutex<[String]>([])
}
