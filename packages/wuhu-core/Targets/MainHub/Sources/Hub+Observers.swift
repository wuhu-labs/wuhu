import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import struct SpaceContract.GroupID
import struct SpaceContract.ObserverInput
import SpaceCore

extension Hub {
  /// Arms `input` as `group`'s observer; who may is the caller's to admit.
  /// Its observation query runs now as the observer, both to refuse what the
  /// group may not read and to pin the baseline.
  nonisolated public func armObserver(_ group: GroupID, _ input: ObserverInput) async throws -> ArmedSubscription {
    @Dependency(\.date) var date
    @Dependency(\.uuid) var uuid
    let terms = try ObserverTerms(name: input.name, sessionsPerHour: input.sessionsPerHour ?? ObserverTerms.defaultSessionsPerHour)
    let handler = try handlerPath(input.handler)
    let observer = Observer(group: group, name: terms.name, firing: nil)
    switch (input.observe, input.timer) {
    case let (observe?, nil):
      let throttle = try SubscriptionArming.observationThrottle(observe.throttleSeconds)
      let baseline = try await space.query(observe.sql, as: observer.principal)
      return try await store.armObserver(
        group, terms,
        slot: .init(id: SubscriptionID("obs.\(uuid().uuidString.lowercased())"), kind: .observe(sql: observe.sql, throttleSeconds: throttle), handler: handler),
        marker: rowsMarker(baseline),
      )
    case let (nil, timer?):
      let (schedule, nextFireAt) = try SubscriptionArming.timerSchedule(inSeconds: timer.inSeconds, cron: timer.cron, now: date.now)
      return try await store.armObserver(
        group, terms,
        slot: .init(id: SubscriptionID("timer.\(uuid().uuidString.lowercased())"), kind: .timer(schedule, message: ""), handler: handler),
        nextFireAt: nextFireAt,
      )
    default:
      throw ArmingProblem("an observer is exactly one of observe and timer")
    }
  }

  nonisolated public func cancelObserver(_ group: GroupID, name: String) async throws -> ArmedSubscription {
    try await store.cancelObserver(group, name: name)
  }

  nonisolated public func observers(_ group: GroupID) async throws -> [ArmedSubscription] {
    try await store.observers(group)
  }
}
