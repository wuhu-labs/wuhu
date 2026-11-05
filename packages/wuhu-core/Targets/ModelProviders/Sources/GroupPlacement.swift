import enum Credentials.ChatGPTAuthError
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
  public var usedPercent: Double?
  public var resetsAt: Double?
  public var capacity: Double
  public var remaining: Double?
  public var score: Double?

  public init(name: String, usedPercent: Double?, resetsAt: Double?, capacity: Double, remaining: Double?, score: Double?) {
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
  /// The lowest score ÷ capacity among windows shorter than the longest; below 1 the member burns ahead of its pace.
  public var shortWindowPace: Double?

  public init(member: String, observedAt: Double?, windows: [ModelHeadroomWindow], score: Double?, shortWindowPace: Double? = nil) {
    self.member = member
    self.observedAt = observedAt
    self.windows = windows
    self.score = score
    self.shortWindowPace = shortWindowPace
  }
}

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

extension ModelsDocument {
  /// The effort a session on group `id` runs at: `effort`, else the group's default.
  public func validateGroup(_ id: String, effort: String? = nil) throws(CatalogError) -> String {
    let group = try validatedGroup(id, effort: effort).declaration
    return effort ?? group.defaultEffort
  }

  /// The group with its failing members left out, and each one's error; it throws when its
  /// declaration fails, its `select` member fails or every member does.
  public func validatedGroup(_ id: String, effort: String? = nil) throws(CatalogError) -> (declaration: Group, memberErrors: [String: CatalogError]) {
    if let error = groupErrors[id] { throw error }
    guard !id.isEmpty, var group = groups[id] else { throw .unknownGroup(id) }
    guard providerErrors[id] == nil, providers[id] == nil, !group.members.isEmpty else {
      throw .invalidGroup(group: id, reason: "group must have members and cannot also be a provider")
    }
    var ids: Set<String> = []
    var pairs: Set<[String]> = []
    for member in group.members {
      guard !member.id.isEmpty, !member.provider.isEmpty, !member.model.isEmpty,
            ids.insert(member.id).inserted, pairs.insert([member.provider, member.model]).inserted
      else {
        throw .groupMember(group: id, member: member.id, reason: .invalidGroup(group: id, reason: "empty or duplicate member id/provider/model pair"))
      }
    }
    if case let .select(member) = group.policy, !ids.contains(member) {
      throw .invalidGroup(group: id, reason: "select member \(member) does not exist")
    }
    var errors: [String: CatalogError] = [:]
    for member in group.members {
      do throws(CatalogError) {
        _ = try validated(provider: member.provider, model: member.model, effort: group.defaultEffort)
        if let effort { _ = try validated(provider: member.provider, model: member.model, effort: effort) }
      } catch { errors[member.id] = .groupMember(group: id, member: member.id, reason: error) }
    }
    if case let .select(member) = group.policy, let error = errors[member] { throw error }
    let firstError = group.members.compactMap { errors[$0.id] }.first
    if let firstError, errors.count == group.members.count { throw firstError }
    group.members.removeAll { errors[$0.id] != nil }
    return (group, errors)
  }

  /// ``validateGroup(_:effort:)``, then `ready` for each usable member at that effort; a member
  /// that is not ready fails the group.
  public func validateGroupReadiness(
    _ id: String, effort: String? = nil, ready: (_ member: Member, _ effort: String) async throws -> Void,
  ) async throws -> String {
    let effort = try validateGroup(id, effort: effort)
    for member in try validatedGroup(id, effort: effort).declaration.members {
      do {
        try await ready(member, effort)
      } catch ChatGPTAuthError.loginRequired {
        throw CatalogError.groupMember(group: id, member: member.id, reason: .credentialLoginRequired(provider: member.provider))
      } catch let error as CatalogError {
        throw CatalogError.groupMember(group: id, member: member.id, reason: error)
      } catch {
        throw CatalogError.groupMember(group: id, member: member.id, reason: .invalidGroup(group: id, reason: "credential readiness failed"))
      }
    }
    return effort
  }

  /// Every group entry that fails to decode or to validate, with its error.
  public var invalidGroups: [String: CatalogError] {
    var errors = groupErrors
    for id in groups.keys {
      do throws(CatalogError) { _ = try validateGroup(id) }
      catch { errors[id] = error }
    }
    return errors
  }

  /// The failing members of each group that validates.
  public var groupMemberErrors: [String: [String: CatalogError]] {
    var errors: [String: [String: CatalogError]] = [:]
    for id in groups.keys {
      if let members = try? validatedGroup(id).memberErrors, !members.isEmpty { errors[id] = members }
    }
    return errors
  }

  /// The efforts every usable member of `group` takes.
  public func effortLevels(of group: Group) -> [String] {
    let efforts = group.members.compactMap { providers[$0.provider]?.models[$0.model].map { Set($0.efforts) } }
    return efforts.dropFirst().reduce(efforts.first ?? []) { $0.intersection($1) }.sorted()
  }
}

public func placeModelGroup(
  id: String,
  group: ModelsDocument.Group,
  providers: [String: ModelsDocument.Provider],
  usage: [String: ModelUsageSnapshot],
  now: Date,
  reason: ModelPlacementReason,
) throws -> ModelPlacement {
  let group = try ModelsDocument(providers: providers, groups: [id: group]).validatedGroup(id).declaration
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
