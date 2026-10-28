import Contract
import JSONValue

// A group's observer: a handler the group runs on an observation or a timer,
// named by a slug unique in the group. Exactly one of observe and timer.
@Contract
public struct ObserverInput: Codable, Equatable, Sendable {
  public let name: String
  public let handler: String
  public let observe: SubscriptionObserveInput?
  public let timer: ObserverTimerInput?
  public let sessionsPerHour: Int?
}

// One of inSeconds (fire once) and cron (fire repeatedly, five UTC fields).
@Contract
public struct ObserverTimerInput: Codable, Equatable, Sendable {
  public let inSeconds: Double?
  public let cron: String?
}

@Contract
public enum ObserverStatusPayload: String, Codable, Equatable, Sendable {
  case armed
  case paused
}

// fireAt is the next firing (unix seconds) of a timer; lastError says why a
// paused observer stopped.
@Contract
public struct ObserverOutput: Codable, Equatable, Sendable {
  public let name: String
  public let id: String
  public let group: String
  public let kind: SubscriptionKindPayload
  public let handler: String
  public let sql: String?
  public let url: String?
  public let cron: String?
  public let fireAt: Double?
  public let status: ObserverStatusPayload
  public let sessionsPerHour: Int
  public let lastFiredAt: Double?
  public let lastError: String?
}

@Contract
public struct ObserversOutput: Codable, Equatable, Sendable {
  public let observers: [ObserverOutput]
}
