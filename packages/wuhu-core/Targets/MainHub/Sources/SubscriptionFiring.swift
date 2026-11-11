import Dependencies
import TaskLifetime
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct GRDB.DatabaseError
import Logging
import SessionDomain
@_spi(SessionObservation) import SpaceCore

public struct SubscriptionFiring: Sendable {
  let space: Space
  var log = Logger(label: "wuhu.subscription-firing")
  var observationStream: @Sendable (Space, Principal, String) async throws -> AsyncThrowingStream<Rows, any Error> = { space, principal, sql in
    await space.observeQuery(sql, throttle: .zero, as: principal)
  }

  /// Mails a slot's owner: a handler slot's observer cell, or the session's cell for a plain one. Main writes no slot: an owner that can no longer act ends its own when the mail comes.
  private let observe: @Sendable (SubscriptionOwner, SubscriptionID, ObserverMail) async throws -> Void

  public init(space: Space, observe: @escaping @Sendable (SubscriptionOwner, SubscriptionID, ObserverMail) async throws -> Void) {
    self.space = space
    self.observe = observe
  }

  public func run() async {
    @Dependency(\.continuousClock) var clock
    while !Task.isCancelled {
      do {
        try await runRegistry()
      } catch is CancellationError {
        return
      } catch {
        log.warning("the subscription registry ended; re-subscribing: \(error)")
        do {
          try await clock.sleep(for: .seconds(1))
        } catch {
          return
        }
      }
    }
  }

  private func runRegistry() async throws {
    let taskScope = TaskScope()
    let (events, post) = AsyncStream.makeStream(of: RegistryEvent.self)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          for try await _ in space.sessions.observeArmedSubscriptions() {
            post.yield(.changed)
          }
          if Task.isCancelled {
            post.finish()
          } else {
            post.yield(.failed(FiringFailure.registryStreamEnded))
          }
        } catch {
          post.yield(.failed(error))
        }
      }
      var running: [Registration: (generation: Int, task: Task<Void, Never>)] = [:]
      var retries: [Registration: Int] = [:]
      var cells: Set<Registration> = []
      var generation = 0
      var failure: (any Error)?
      do {
        for await event in events {
          if Task.isCancelled { break }
          var completion: (Registration, Result<Void, any Error>)?
          switch event {
          case .changed:
            break
          case let .finished(arming, completedGeneration, outcome):
            guard running[arming]?.generation == completedGeneration else { continue }
            let completed = running.removeValue(forKey: arming)!
            await completed.task.value
            completion = (arming, outcome)
          case let .failed(error):
            throw error
          }
          let registrations = try await space.sessions.subscriptionRegistrations()
          let current = registrations.map { (Registration($0.subscription, callbackID: $0.callbackID, orphaned: $0.orphaned), $0.subscription) }
          let keys = Set(current.map(\.0))
          retries = retries.filter { keys.contains($0.key) }
          // An observer cell reads its slot itself: it hears of every change.
          let handlers = Set(current.filter { $0.1.slot.handler != nil }.map(\.0))
          for arming in Set(handlers.symmetricDifference(cells).map { Pair(owner: $0.owner, subscription: $0.subscription) }) {
            try await observe(arming.owner, arming.subscription, .look)
          }
          cells = handlers
          if let (arming, outcome) = completion, keys.contains(arming) {
            if case let .failure(error) = outcome, !(error is CancellationError) {
              log.warning("observation \(arming.subscription.rawValue) failed: \(error)")
            }
            retries[arming] = min(max(1, (retries[arming] ?? 0) * 2), 60)
          }
          // A gone slot's observation is stopped, not waited for: its end is a
          // stale generation, and the scope joins it on the way out.
          for (arming, job) in running where !keys.contains(arming) {
            job.task.cancel()
            running[arming] = nil
          }
          for (arming, subscription) in current where running[arming] == nil {
            guard subscription.slot.handler != nil || subscription.owner.session != nil else { continue }
            let sql: String
            switch subscription.slot.kind {
            case let .observe(query, _): sql = query
            case .children:
              guard case let .session(parent) = subscription.owner else { continue }
              sql = SubscriptionSlot.childrenQuery(parent)
            case .stream, .timer: continue
            }
            guard let callbackID = arming.callbackID else { continue }
            generation += 1
            let startedGeneration = generation
            let backoff = retries[arming] ?? 0
            running[arming] = (startedGeneration, try taskScope.run("subscription-firing") {
              let outcome: Result<Void, any Error>
              do {
                @Dependency(\.continuousClock) var clock
                if backoff > 0 { try await clock.sleep(for: .seconds(backoff)) }
                try Task.checkCancellation()
                try await runObservation(subscription, callbackID: callbackID, sql: sql)
                outcome = .success(())
              } catch {
                outcome = .failure(error)
              }
              post.yield(.finished(arming, startedGeneration, outcome))
            })
          }
        }
      } catch {
        failure = error
      }
      group.cancelAll()
      post.finish()
      for job in running.values { job.task.cancel() }
      for job in running.values { await job.task.value }
      await taskScope.close()
      if let failure { throw failure }
    }
  }

  private func runObservation(_ subscription: ArmedSubscription, callbackID: UUID, sql: String) async throws {
    var delivered = subscription.marker
    var snapshots = try await observationStream(space, principal(of: subscription), sql).makeAsyncIterator()
    while !Task.isCancelled {
      let rows: Rows?
      do {
        rows = try await snapshots.next()
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        guard invalidObservationQuery(error) else { throw error }
        log.warning("observation \(subscription.slot.id.rawValue) query failed: \(error)")
        let cancelled = "observation \(subscription.slot.id.rawValue) failed and was cancelled: \(error)"
        if subscription.slot.handler == nil {
          try await observe(subscription.owner, subscription.slot.id, .plain(callbackID, .failed(text: cancelled)))
        } else {
          try await observe(subscription.owner, subscription.slot.id, .failed(subscription.owner.session == nil ? "observation query failed: \(error)" : cancelled))
        }
        return
      }
      guard let rows else { throw FiringFailure.observationStreamEnded }
      let marker: String
      if case .children = subscription.slot.kind {
        // Its marker is the errored children last seen: only one joining them is news.
        let errored = rows.rows.compactMap { if case let .text(id) = $0[0] { id } else { nil } }
        marker = errored.joined(separator: ",")
        if Set(errored).isSubset(of: (delivered ?? "").split(separator: ",").map(String.init)) {
          if marker != delivered ?? "" { try await observe(subscription.owner, subscription.slot.id, .plain(callbackID, .quiet(marker: marker))) }
          delivered = marker
          continue
        }
      } else {
        marker = rowsMarker(rows)
        guard marker != delivered else { continue }
      }
      if subscription.slot.handler != nil {
        try await observe(subscription.owner, subscription.slot.id, .rows(handlerInput(rows), marker: marker))
        delivered = marker
        continue
      }
      try await observe(subscription.owner, subscription.slot.id, .plain(callbackID, .change(text: observedText(subscription.slot.kind, sql: sql, rows: rows), marker: marker)))
      delivered = marker
    }
    throw CancellationError()
  }

  private func principal(of subscription: ArmedSubscription) async throws -> Principal {
    switch subscription.owner {
    case let .session(id): try await space.principal(of: id)
    case let .group(group): Observer(group: group, name: subscription.name!, firing: nil).principal
    }
  }
}

private func invalidObservationQuery(_ error: any Error) -> Bool {
  if let error = error as? DatabaseError {
    return error.resultCode == .SQLITE_ERROR || error.resultCode == .SQLITE_MISUSE
  }
  guard let error = error as? SpaceError else { return false }
  switch error {
  case .queryNotReadOnly, .queryForbiddenTable, .queryResultTooLarge, .unknownRelation:
    return true
  default:
    return false
  }
}

private enum FiringFailure: Error {
  case registryStreamEnded
  case observationStreamEnded
}

private enum RegistryEvent: Sendable {
  case changed
  case finished(Registration, Int, Result<Void, any Error>)
  case failed(any Error)
}

private struct Pair: Hashable {
  var owner: SubscriptionOwner
  var subscription: SubscriptionID
}

private struct Registration: Hashable, Sendable {
  var owner: SubscriptionOwner
  var subscription: SubscriptionID
  var kind: SubscriptionSlot.Kind
  var nextFireAt: Date?
  var callbackID: UUID?
  var handlerIncarnation: UUID?
  var orphaned: Bool

  init(_ armed: ArmedSubscription, callbackID: UUID?, orphaned: Bool) {
    owner = armed.owner
    subscription = armed.slot.id
    kind = armed.slot.kind
    nextFireAt = armed.nextFireAt
    self.callbackID = callbackID
    handlerIncarnation = armed.slot.handlerIncarnation
    self.orphaned = orphaned
  }
}

private func observedText(_ kind: SubscriptionSlot.Kind, sql: String, rows: Rows) -> String {
  guard case .children = kind else { return "observed change for \(sql):\n" + renderedRows(rows) }
  return "Your children errored:\n" + renderedRows(rows)
}
