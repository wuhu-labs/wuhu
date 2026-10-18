import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public enum ModelPlacementReason: String, Hashable, Sendable, Codable {
  case create
  case startOver
  case compaction
}

public struct ModelHeadroomWindow: Hashable, Sendable, Codable {
  public var name: String
  public var usedPercent: Double
  public var resetsAt: Double?
  public var capacity: Double
  public var remaining: Double
  public var score: Double

  public init(name: String, usedPercent: Double, resetsAt: Double?, capacity: Double, remaining: Double, score: Double) {
    self.name = name
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.capacity = capacity
    self.remaining = remaining
    self.score = score
  }
}

public struct ModelPlacementEvidence: Hashable, Sendable, Codable {
  public var member: String
  public var observedAt: Double?
  public var windows: [ModelHeadroomWindow]
  public var score: Double?

  public init(member: String, observedAt: Double?, windows: [ModelHeadroomWindow], score: Double?) {
    self.member = member
    self.observedAt = observedAt
    self.windows = windows
    self.score = score
  }
}

public struct SessionModelRoute: Hashable, Sendable, Codable {
  public var group: String?
  public var member: String?
  public var specifier: ModelSpecifier
  public var bindingFingerprint: String
  public var epoch: String
  public var reason: ModelPlacementReason
  public var placedAt: Date
  public var evidence: [ModelPlacementEvidence]
  public var failure: ModelRouteFailure?
  public var switchCause: ModelRouteFailure.Reason?

  public var decisionReason: String { switchCause.map { "lastResort:" + $0.rawValue } ?? reason.rawValue }

  public init(group: String?, member: String?, specifier: ModelSpecifier, bindingFingerprint: String, epoch: String, reason: ModelPlacementReason, placedAt: Date, evidence: [ModelPlacementEvidence], failure: ModelRouteFailure? = nil, switchCause: ModelRouteFailure.Reason? = nil) {
    self.switchCause = switchCause
    self.failure = failure
    self.group = group
    self.member = member
    self.specifier = specifier
    self.bindingFingerprint = bindingFingerprint
    self.epoch = epoch
    self.reason = reason
    self.placedAt = placedAt
    self.evidence = evidence
  }
}

public struct ModelRouteFailure: Hashable, Sendable, Codable {
  public enum Reason: String, Hashable, Sendable, Codable { case quota, authentication, upstreamOutage }
  public enum Source: String, Hashable, Sendable, Codable { case upstream, credentialRefresh }
  public var source: Source
  public var code: String
  public var reason: Reason
  public var firstFailureAt: Date
  public var lastFailureAt: Date?
  public var deadline: Date
  public var retryAt: Date?
  public var consecutiveFailures: Int

  public init(reason: Reason, firstFailureAt: Date, deadline: Date, retryAt: Date?, consecutiveFailures: Int = 1, source: Source = .upstream, code: String = "refusal", lastFailureAt: Date? = nil) {
    self.lastFailureAt = lastFailureAt
    self.source = source
    self.code = code
    self.reason = reason
    self.firstFailureAt = firstFailureAt
    self.deadline = deadline
    self.retryAt = retryAt
    self.consecutiveFailures = consecutiveFailures
  }

  public var refusing: Bool { reason != .upstreamOutage || consecutiveFailures >= 3 }
  public var evidenceExpiresAt: Date { retryAt ?? max(deadline, (lastFailureAt ?? firstFailureAt).addingTimeInterval(60)) }
}

public struct ModelRouteTransition: Sendable, Codable {
  public var expectedEpoch: String
  public var route: SessionModelRoute
  public var transcript: Transcript

  public init(expectedEpoch: String, route: SessionModelRoute, transcript: Transcript) {
    self.expectedEpoch = expectedEpoch
    self.route = route
    self.transcript = transcript
  }
}

/// The model a `compact` call asked to continue on: `provider/model` or a
/// model-group id, with an optional effort. The switch commits with the
/// compaction or not at all.
public struct CompactionTarget: Hashable, Sendable {
  public var model: String
  public var effort: String?

  public init(model: String, effort: String? = nil) {
    self.model = model
    self.effort = effort
  }
}

extension Transcript {
  /// The notice for a switch the session asked for at its own compaction
  /// when it leaves or changes its group: `from`/`to` are `provider/model`
  /// for a concrete target and `group:member` for a group placement.
  public mutating func appendRequestedSwitchNotice(from: String, to: String) {
    @Dependency(\.uuid) var uuid
    @Dependency(\.date.now) var now
    append(.notification(.init(id: uuid(), timestamp: now, kind: .context, subscriptionID: SubscriptionID("model-route"), content: .init(text: "Model switched \(from) → \(to) (requested at compaction). Account-bound reasoning and provider records were not carried. Continue the outstanding request; re-read material if needed."))))
  }

  public mutating func appendRouteNotice(group: String, from: String, to: String, reason: String) {
    @Dependency(\.uuid) var uuid
    @Dependency(\.date.now) var now
    append(.notification(.init(id: uuid(), timestamp: now, kind: .context, subscriptionID: SubscriptionID("model-route"), content: .init(text: "Model group \(group) moved \(from) → \(to) (\(reason)). Account-bound reasoning and provider records were not carried. Continue the outstanding request; re-read material if needed."))))
  }
}
