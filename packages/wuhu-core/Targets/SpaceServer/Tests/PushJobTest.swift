import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import SpaceCore
@testable import SpaceServer
import Testing
import Wuwei

struct WebPushJobTest {
  var space: Space
  var logger: Logger
  var client: WebPushClient

  func drain() async throws {
    try await drainJob(space, logger: logger, webPush: client, pushRelay: PushRelayClient { _ in }, id: "web-push", transport: .webPush) {
      @Dependency(\.date.now) var now
      return try await space.dueWebPushDeliveries(at: now).isEmpty
    }
  }
}

struct PushRelayJobTest {
  var space: Space
  var logger: Logger
  var client: PushRelayClient

  func drain() async throws {
    try await drainJob(space, logger: logger, webPush: WebPushClient { _ in }, pushRelay: client, id: "push-relay", transport: .pushRelay) {
      @Dependency(\.date.now) var now
      return try await space.duePushRelayDeliveries(at: now).isEmpty
    }
  }
}

private func drainJob(_ space: Space, logger: Logger, webPush: WebPushClient, pushRelay: PushRelayClient, id: String, transport: NotificationDeliveryJob.Params, drained: () async throws -> Bool) async throws {
  let worker = space.worker
  worker.provide(notificationDeliveryClient(space: space, logger: logger, webPush: webPush, pushRelay: pushRelay))
  worker.register(.job(NotificationDeliveryJob.self))
  try worker.create(NotificationDeliveryJob.ID(id), params: transport)
  worker.start()
  do {
    try await outboxEventually("the job commits its drain", drained)
  } catch {
    await space.stopWorker()
    throw error
  }
  await space.stopWorker()
}

func outboxEventually(_ description: String, _ condition: () async throws -> Bool) async throws {
  for _ in 0 ..< 10000 {
    if try await condition() { return }
    await Task.yield()
  }
  Issue.record("no progress: \(description)")
  throw OutboxTestStalled()
}

private struct OutboxTestStalled: Error {}
