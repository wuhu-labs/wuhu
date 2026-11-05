import Dependencies
import struct ModelProviders.ModelPlacementEvidence
import enum ModelProviders.ModelPlacementReason
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

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

  public init(group: String?, member: String?, specifier: ModelSpecifier, bindingFingerprint: String, epoch: String, reason: ModelPlacementReason, placedAt: Date, evidence: [ModelPlacementEvidence], failure: ModelRouteFailure? = nil) {
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
  public var retryAt: Date?
  public var consecutiveFailures: Int

  public init(reason: Reason, firstFailureAt: Date, retryAt: Date?, consecutiveFailures: Int = 1, source: Source = .upstream, code: String = "refusal", lastFailureAt: Date? = nil) {
    self.lastFailureAt = lastFailureAt
    self.source = source
    self.code = code
    self.reason = reason
    self.firstFailureAt = firstFailureAt
    self.retryAt = retryAt
    self.consecutiveFailures = consecutiveFailures
  }

  public var refusing: Bool { reason != .upstreamOutage || consecutiveFailures >= 3 }

  /// An authentication refusal stands until a success clears it; any other until its retry time, or a minute past the last failure without one.
  public func stands(at now: Date) -> Bool {
    switch reason {
    case .authentication: true
    case .quota, .upstreamOutage: (retryAt ?? (lastFailureAt ?? firstFailureAt).addingTimeInterval(60)) > now
    }
  }
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

  public mutating func appendRouteNotice(group: String, from: String, to: String, reason: ModelPlacementReason) {
    @Dependency(\.uuid) var uuid
    @Dependency(\.date.now) var now
    append(.notification(.init(id: uuid(), timestamp: now, kind: .context, subscriptionID: SubscriptionID("model-route"), content: .init(text: "Model group \(group) moved \(from) → \(to) (\(reason.rawValue)). Account-bound reasoning and provider records were not carried. Continue the outstanding request; re-read material if needed."))))
  }
}
