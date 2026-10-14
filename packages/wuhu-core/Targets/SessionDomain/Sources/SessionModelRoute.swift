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

  public init(group: String?, member: String?, specifier: ModelSpecifier, bindingFingerprint: String, epoch: String, reason: ModelPlacementReason, placedAt: Date, evidence: [ModelPlacementEvidence]) {
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
