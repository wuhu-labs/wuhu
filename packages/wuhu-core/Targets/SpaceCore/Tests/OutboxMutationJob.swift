#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import SpaceCore
import Testing
import Wuwei

@Job
struct OutboxMutationJob {
  enum Params: Codable {
    case commit(String, Int64)
    case postpone(String, Date)
  }

  typealias Message = Never
  static let schema = ["CREATE TABLE outbox_test_steps (\(ownerColumn), UNIQUE(owner))"]

  nonisolated(nonsending) mutating func start() async throws -> Outcome {
    switch ctx.params {
    case let .commit(endpoint, notification):
      try db.markWebPushDelivered(endpoint: endpoint, notification: notification, at: fixedDate)
    case let .postpone(endpoint, date):
      try db.deferWebPushDelivery(endpoint: endpoint, until: date, at: fixedDate)
    }
    try db.execute("INSERT INTO outbox_test_steps DEFAULT VALUES")
    return .done
  }

  func applied() -> Bool {
    db.one("SELECT 1 FROM outbox_test_steps WHERE owner = ?", .text(id.key)) != nil
  }
}

func mutateOutbox(_ space: Space, _ params: OutboxMutationJob.Params) async throws {
  let worker = space.worker
  worker.register(.job(OutboxMutationJob.self))
  let id = OutboxMutationJob.ID(UUID().uuidString)
  try worker.create(id, params: params)
  for _ in 0 ..< 10000 {
    if worker.job(id).applied() {
      await space.stopWorker()
      return
    }
    await Task.yield()
  }
  await space.stopWorker()
  Issue.record("the mutation job made no progress")
}
