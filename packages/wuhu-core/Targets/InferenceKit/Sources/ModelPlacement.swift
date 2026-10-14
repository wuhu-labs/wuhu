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

    public init(name: String, usedPercent: Double?, resetsAt: Double?) {
      self.name = name
      self.usedPercent = usedPercent
      self.resetsAt = resetsAt
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
  _ = try ProviderCatalog(document: ModelsDocument(providers: providers, groups: [id: group]), credentials: .unavailable).validateGroup(id)
  let evidence = group.members.map { member in
    let snapshot = usage[member.provider]
    let windows = (snapshot?.windows ?? []).compactMap { window -> ModelHeadroomWindow? in
      let capacityKey: String
      let duration: Double
      switch window.name {
      case "five_hour": capacityKey = "fiveHour"; duration = 5 * 3600
      case "seven_day": capacityKey = "sevenDay"; duration = 7 * 24 * 3600
      default: return nil
      }
      guard let used = window.usedPercent, used.isFinite, used >= 0 else { return nil }
      let reset = window.resetsAt.flatMap { $0.isFinite ? $0 : nil }
      let expired = reset.map { $0 <= now.timeIntervalSince1970 } ?? false
      let capacity = providers[member.provider]?.capacity?[capacityKey] ?? 1
      let remaining = (expired ? 1 : max(0, 1 - used / 100)) * capacity
      let secondsLeft = expired ? duration : reset.map { max(60, $0 - now.timeIntervalSince1970) } ?? duration
      let score = min(Double.greatestFiniteMagnitude, remaining / min(1, secondsLeft / duration))
      return ModelHeadroomWindow(name: window.name, usedPercent: used, resetsAt: reset, capacity: capacity, remaining: remaining, score: score)
    }
    return ModelPlacementEvidence(member: member.id, observedAt: snapshot?.observedAt, windows: windows, score: windows.map(\.score).min())
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
