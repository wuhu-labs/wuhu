import JSONValue
import ServerTelemetry
import SessionDomain
import struct SpaceContract.GroupID
import enum SpaceCore.HandlerOutcome
import enum SpaceCore.SubscriptionOwner
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// One handler firing as a job: the module at `path` run on `input` as the slot's owner (its session, or its group's observer in this firing), the outcome sent to its observer cell. A rerun after a crash runs it again: a handler runs at least once.
@Job
struct HandlerJob {
  typealias Message = Never

  struct Params: Codable {
    let cell: ObserverCell.ID
    let owner: SubscriptionOwner
    let subscription: SubscriptionID
    let name: String?
    let group: GroupID
    let firing: UUID
    let path: String
    let input: JSONValue
    /// The rows it fires on, when it fires on rows.
    let marker: String?
    let fireTime: Date?
  }

  mutating func start() async throws -> Outcome {
    let client = ctx.dependency(LoopClient.self)
    let params = ctx.params
    let outcome = try await ctx.effect { try await client.fire(params) }
    let answer = HandlerAnswer(firing: params.firing, path: params.path, marker: params.marker, fireTime: params.fireTime, outcome: outcome)
    return .done(sending: .fired(id, answer), to: params.cell.recipient)
  }
}

struct HandlerAnswer: Codable, Sendable {
  let firing: UUID
  let path: String
  let marker: String?
  let fireTime: Date?
  let outcome: HandlerOutcome
}

extension LoopClient {
  /// Runs the handler as a firing span of its own, under its session or group; what it says stays out of the span.
  func fire(_ params: HandlerJob.Params) async throws -> HandlerOutcome {
    try await dependencies.yield {
      let kind: FiringKind = params.fireTime != nil ? .timer : params.input.object?["event"] != nil ? .stream : .observe
      let lag = params.fireTime.map { max(0, Int(now().timeIntervalSince($0) * 1000)) }
      return try await traced(.firing, under: .root(SpanOwner(session: params.owner.session, group: params.group))) { span in
        span.set(.subscription, params.subscription)
        span.set(.firing, params.firing.uuidString.lowercased())
        span.set(.firingKind, kind)
        span.set(.observer, params.owner.group == nil ? nil : params.name)
        span.set(.lagMs, lag)
        do {
          let result = try await handler(params)
          span.set(.wakes, result.wakes.count)
          span.conclude(.ok)
          return .ok(wakes: result.wakes)
        } catch {
          // A handler stopped with its worker says so in its own words: it did not fail, it runs again.
          if error is CancellationError || Task.isCancelled { throw CancellationError() }
          span.conclude(.errored)
          return .failed(String(describing: error))
        }
      }
    }
  }
}
