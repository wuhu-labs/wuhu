#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import struct MainHub.ObserveArguments
import enum MainHub.SubscriptionArming
import struct MainHub.TimerArguments
import struct MainHub.ToolProblem
import OrderedCollections
import SessionDomain
import SpaceContract
import SpaceCore

// The session's durable slots: main keys each on the tool call that arms it,
// so a retried arm lands on the same slot.
extension ToolExecutor {
  func observe(_ session: SessionID, _ call: String, _ arguments: ObserveArguments) async throws -> ToolResultPayload {
    let source: ObservedSource
    do {
      source = try SubscriptionArming.observedSource(sql: arguments.sql, url: arguments.url)
    } catch {
      throw ToolProblem(error.message)
    }
    var observe: OrderedDictionary<String, JSONValue> = [:]
    observe["sql"] = arguments.sql.map(JSONValue.string)
    observe["url"] = arguments.url.map(JSONValue.string)
    observe["throttleSeconds"] = arguments.throttleSeconds.map(JSONValue.number)
    var body: OrderedDictionary<String, JSONValue> = ["observe": .object(observe)]
    body["handler"] = arguments.handler.map(JSONValue.string)
    body["name"] = arguments.name.map(JSONValue.string)
    let armed: SubscriptionOutput = try await verb(.session(session), call, .post, "/v1/subscription", body: .object(body))
    return .observe(.init(subscriptionID: SubscriptionID(armed.id), source: source))
  }

  func timer(_ session: SessionID, _ call: String, _ arguments: TimerArguments) async throws -> ToolResultPayload {
    var timer: OrderedDictionary<String, JSONValue> = ["message": .string(arguments.message)]
    timer["inSeconds"] = arguments.inSeconds.map(JSONValue.number)
    timer["cron"] = arguments.cron.map(JSONValue.string)
    var body: OrderedDictionary<String, JSONValue> = ["timer": .object(timer)]
    body["handler"] = arguments.handler.map(JSONValue.string)
    body["name"] = arguments.name.map(JSONValue.string)
    let armed: SubscriptionOutput = try await verb(.session(session), call, .post, "/v1/subscription", body: .object(body))
    let schedule: TimerSchedule = switch (armed.cron, armed.fireAt) {
    case let (cron?, _): .cron(cron)
    case let (nil, fireAt?): .oneShot(Date(timeIntervalSince1970: fireAt))
    case (nil, nil): throw ToolProblem("timer \(armed.id) was armed without a schedule")
    }
    return .timer(.init(subscriptionID: SubscriptionID(armed.id), schedule: schedule, message: arguments.message))
  }

  func cancelSubscription(_ session: SessionID, _ call: String, _ id: String) async throws -> ToolResultPayload {
    let ended: SubscriptionOutput = try await verb(.session(session), call, .delete, "/v1/subscription/\(id)")
    return switch ended.kind {
    case .observe: .cancelObservation(.init(subscriptionID: SubscriptionID(ended.id)))
    case .timer: .cancelTimer(.init(subscriptionID: SubscriptionID(ended.id)))
    }
  }
}
