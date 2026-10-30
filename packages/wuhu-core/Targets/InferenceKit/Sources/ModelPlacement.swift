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
  let evidence = group.members.map { member in
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
    return ModelPlacementEvidence(member: member.id, observedAt: snapshot?.observedAt, windows: windows.map(\.evidence), score: score)
  }
  let chosen: ModelsDocument.Member?
  switch group.policy {
  case let .select(member): chosen = group.members.first { $0.id == member }
  case .quotaAware:
    let scores = Dictionary(uniqueKeysWithValues: evidence.map { ($0.member, $0.score) })
    chosen = group.members.filter { (scores[$0.id] ?? nil).map { $0 > 0 } ?? true }.sorted { lhs, rhs in
      let left = scores[lhs.id] ?? nil
      let right = scores[rhs.id] ?? nil
      if left != right { return (left ?? -1) > (right ?? -1) }
      return lhs.id < rhs.id
    }.first
  }
  guard let chosen else { throw CatalogError.noUsableMembers(id) }
  return ModelPlacement(member: chosen, reason: reason, evidence: evidence)
}
