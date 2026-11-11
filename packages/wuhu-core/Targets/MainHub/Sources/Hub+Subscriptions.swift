import Crypto
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import SpaceCore
import SpaceTools

extension SubscriptionID {
  static func observation(_ callID: ToolCallID) -> SubscriptionID {
    SubscriptionID("obs.\(callID.rawValue)")
  }

  static func timer(_ callID: ToolCallID) -> SubscriptionID {
    SubscriptionID("timer.\(callID.rawValue)")
  }
}

extension Hub {
  /// What an `observe` call arms. A query runs now as the subscriber, both to refuse what it may not read and to pin the baseline: arming never fires on rows that already existed. A stream starts at its next event.
  nonisolated public func arming(_ session: SessionID, _ callID: ToolCallID, _ arguments: ObserveArguments) async throws -> Arming {
    let source: ObservedSource
    let throttle: Double
    do {
      source = try SubscriptionArming.observedSource(sql: arguments.sql, url: arguments.url)
      throttle = try SubscriptionArming.observationThrottle(arguments.throttleSeconds)
    } catch {
      throw ToolProblem(error.message)
    }
    let (handler, name) = (try handlerPath(arguments.handler), try subscriptionName(arguments.name))
    let (kind, marker) = try await observation(source, throttle: throttle, as: try await space.principal(of: session))
    return Arming(.init(id: .observation(callID), kind: kind, handler: handler), name: name, marker: marker)
  }

  nonisolated func observation(
    _ source: ObservedSource,
    throttle: Double,
    as principal: Principal,
  ) async throws -> (kind: SubscriptionSlot.Kind, marker: String?) {
    switch source {
    case let .query(sql): (.observe(sql: sql, throttleSeconds: throttle), rowsMarker(try await space.query(sql, as: principal)))
    case let .stream(url): (.stream(url: url, throttleSeconds: throttle), nil)
    }
  }

  /// What a `timer` call arms.
  nonisolated public func arming(_ callID: ToolCallID, _ arguments: TimerArguments) throws -> Arming {
    @Dependency(\.date) var date
    let schedule: TimerSchedule
    let nextFireAt: Date
    do {
      (schedule, nextFireAt) = try SubscriptionArming.timerSchedule(
        inSeconds: arguments.inSeconds, cron: arguments.cron, now: date.now,
      )
    } catch {
      throw ToolProblem(error.message)
    }
    return Arming(
      .init(id: .timer(callID), kind: .timer(schedule, message: arguments.message), handler: try handlerPath(arguments.handler)),
      name: try subscriptionName(arguments.name), nextFireAt: nextFireAt,
    )
  }
}

func handlerPath(_ path: String?) throws -> String? {
  guard let path else { return nil }
  let resolved = try resolveScriptModule(path.hasPrefix("/") ? "wuhu:" + path : path, from: "script")
  return path.hasPrefix("/") ? String(resolved.dropFirst("wuhu:".count)) : resolved
}

func subscriptionName(_ name: String?) throws -> String? {
  guard let name else { return nil }
  guard !name.isEmpty, name.utf8.count <= 64, !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
  else { throw ToolProblem("a subscription name is 1 to 64 bytes with no control characters", code: "invalidArgument") }
  return name
}
