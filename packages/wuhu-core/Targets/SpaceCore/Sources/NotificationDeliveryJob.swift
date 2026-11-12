#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Logging
import Wuwei

@Job
public struct NotificationDeliveryJob {
  public enum Params: String, Codable, Sendable {
    case webPush
    case pushRelay
  }

  public enum Message: Codable, Sendable {
    case changed
  }

  public static let webPush = ID("web-push")
  public static let pushRelay = ID("push-relay")

  public nonisolated(nonsending) mutating func start() async throws -> Outcome {
    let client = ctx.dependency(NotificationDeliveryClient.self)
    switch ctx.params {
    case .webPush: return try await run(client.webPush, logger: client.logger)
    case .pushRelay: return try await run(client.pushRelay, logger: client.logger)
    }
  }

  private var now: Date {
    Date(timeIntervalSince1970: Double(ctx.now.milliseconds) / 1000)
  }

  private nonisolated(nonsending) mutating func run<Delivery>(_ drain: OutboxDrain<Delivery>, logger: Logger) async throws -> Outcome {
    while true {
      try Task.checkCancellation()
      while try await ctx.receive(within: .zero) != nil {}
      try drain.prepare(&db, now)
      let at = now
      let deliveries = try await ctx.effect { try await drain.due(at) }
      if deliveries.isEmpty {
        _ = try await ctx.receive(within: .seconds(15))
        continue
      }
      for delivery in deliveries {
        try Task.checkCancellation()
        let disposition: OutboxDisposition
        do {
          try await ctx.effect { try await drain.deliver(delivery) }
          disposition = .advance
        } catch is CancellationError {
          throw CancellationError()
        } catch let error as Evicted {
          throw error
        } catch {
          disposition = drain.disposition(error, delivery, now)
          logger.warning("notification refused", metadata: ["delivery": drain.describe(delivery), "error": "\(error)"])
        }
        switch disposition {
        case .advance: try drain.commit(&db, delivery, now)
        case .unsubscribe: try drain.withdraw(&db, delivery)
        case let .retry(retryAt): try drain.postpone(&db, delivery, retryAt, now)
        }
      }
    }
  }
}
