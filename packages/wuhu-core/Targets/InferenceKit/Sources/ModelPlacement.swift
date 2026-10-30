#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.ModelHeadroomWindow
import struct SessionDomain.ModelPlacementEvidence
import enum SessionDomain.ModelPlacementReason

public struct ModelUsageSnapshot: Hashable, Sendable {
  public var observedAt: Double
  public var windows: [Window]

  public init(observedAt: Double, windows: [Window]) {
    self.observedAt = observedAt
    self.windows = windows
  }

  public struct Window: Hashable, Sendable {
    public var name: String
    public var usedPercent: Double?
    public var resetsAt: Double?
    public var windowMinutes: Int?

    public init(name: String, usedPercent: Double?, resetsAt: Double?, windowMinutes: Int? = nil) {
      self.name = name
      self.usedPercent = usedPercent
      self.resetsAt = resetsAt
      self.windowMinutes = windowMinutes
    }
  }
}

public struct ModelPlacement: Hashable, Sendable {
  public var member: ModelsDocument.Member
  public var reason: ModelPlacementReason
  public var evidence: [ModelPlacementEvidence]
}

public func placeModelGroup(
  id: String,
  group: ModelsDocument.Group,
  providers: [String: ModelsDocument.Provider],
  usage: [String: ModelUsageSnapshot],
  now: Date,
  reason: ModelPlacementReason,
) throws -> ModelPlacement {
  let group = try ProviderCatalog(document: ModelsDocument(providers: providers, groups: [id: group]), credentials: .unavailable).validatedGroup(id).declaration
  let placed = group.members.map { member -> ModelPlacementEvidence in
    let snapshot = usage[member.provider]
    let provider = providers[member.provider]!
    let windows = provider.models[member.model]!.bindingWindows.map { name -> (minutes: Int?, evidence: ModelHeadroomWindow) in
      let window = snapshot?.windows.first { $0.name == name }
      let capacity = provider.capacity?[name] ?? 1
      let used = window?.usedPercent.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
      let reset = window?.resetsAt.flatMap { $0.isFinite ? $0 : nil }
      var evidence = ModelHeadroomWindow(name: name, usedPercent: used, resetsAt: reset, capacity: capacity, remaining: nil, score: nil)
      guard let minutes = window?.windowMinutes ?? ["five_hour": 300, "seven_day": 10080][name], minutes > 0,
            let used else { return (nil, evidence) }
      let duration = Double(minutes) * 60
      let remaining = max(0, 1 - used / 100) * capacity
      let secondsLeft = reset.map { max(60, $0 - now.timeIntervalSince1970) } ?? duration
      evidence.remaining = remaining
      evidence.score = remaining / min(1, secondsLeft / duration)
      return (minutes, evidence)
    }
    let longest = windows.compactMap(\.minutes).max()
    let score = windows.contains { $0.evidence.remaining == 0 } ? 0
      : windows.contains { $0.evidence.score == nil } ? nil
      : windows.filter { $0.minutes == longest }.compactMap(\.evidence.score).min()
    let shortWindowPace = windows.filter { $0.minutes.map { $0 < longest! } == true }.compactMap { window in window.evidence.score.map { $0 / window.evidence.capacity } }.min()
    return ModelPlacementEvidence(member: member.id, observedAt: snapshot?.observedAt, windows: windows.map(\.evidence), score: score, shortWindowPace: shortWindowPace)
  }
  let chosen: ModelsDocument.Member?
  switch group.policy {
  case let .select(member): chosen = group.members.first { $0.id == member }
  case .quotaAware:
    let rank = { (evidence: ModelPlacementEvidence) -> (Int, Double) in
      guard let score = evidence.score else { return (0, 0) }
      guard let pace = evidence.shortWindowPace, pace < 1 else { return (2, score) }
      return (1, pace)
    }
    chosen = zip(group.members, placed).filter { $1.score.map { $0 > 0 } ?? true }.max { lhs, rhs in
      rank(lhs.1) != rank(rhs.1) ? rank(lhs.1) < rank(rhs.1) : lhs.0.id > rhs.0.id
    }?.0
  }
  guard let chosen else { throw CatalogError.noUsableMembers(id) }
  return ModelPlacement(member: chosen, reason: reason, evidence: placed)
}
