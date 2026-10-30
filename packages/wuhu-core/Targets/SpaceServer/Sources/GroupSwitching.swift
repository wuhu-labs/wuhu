import enum Credentials.ChatGPTAuthError
import Dependencies
import protocol MainHub.Main
import SessionTools
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import LoopCore
import SessionDomain
import WuhuAI

func replacementRoute(_ held: SessionModelRoute, catalog: ProviderCatalog, usage: UsageBoard, reason: ModelPlacementReason) throws -> SessionModelRoute {
  guard let id = held.group else { throw CatalogError.modelRouteInvalid(group: held.group ?? "<direct>", member: held.member ?? "<missing>") }
  let group = try catalog.validatedGroup(id, effort: held.specifier.effort).declaration
  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid
  let placed = try placeModelGroup(id: id, group: group, providers: catalog.document.providers, usage: groupUsage(group, usage: usage, at: now), now: now, reason: reason)
  return .init(group: id, member: placed.member.id, specifier: .init(provider: placed.member.provider, model: placed.member.model, effort: held.specifier.effort), bindingFingerprint: catalog.document.providers[placed.member.provider]!.routeFingerprint, epoch: uuid().uuidString.lowercased(), reason: reason, placedAt: now, evidence: placed.evidence)
}

private func placementCatalog(_ held: SessionModelRoute, catalog: ProviderCatalog) async throws -> ProviderCatalog {
  guard let id = held.group else { throw CatalogError.modelRouteInvalid(group: held.group ?? "<direct>", member: held.member ?? "<missing>") }
  var group = try catalog.validatedGroup(id, effort: held.specifier.effort).declaration
  var eligible: [ModelsDocument.Member] = []
  for member in group.members {
    if member.id == held.member, held.failure?.reason == .authentication { continue }
    do {
      try await catalog.validateReadiness(.init(provider: member.provider, model: member.model, effort: held.specifier.effort))
      eligible.append(member)
    } catch {
      if unavailableCandidate(error, provider: member.provider) { continue }
      if let reason = error as? CatalogError { throw CatalogError.groupMember(group: id, member: member.id, reason: reason) }
      if let auth = error as? ChatGPTAuthError, case .loginRequired = auth { throw CatalogError.groupMember(group: id, member: member.id, reason: .credentialLoginRequired(provider: member.provider)) }
      throw error
    }
  }
  guard !eligible.isEmpty else { throw CatalogError.noUsableMembers(id) }
  @Dependency(\.date.now) var now
  if held.failure?.reason == .quota, let reset = held.failure?.retryAt, reset > now, eligible.contains(where: { $0.id != held.member }) {
    eligible.removeAll { $0.id == held.member }
  }
  var ready = catalog
  group.members = eligible
  ready.document.groups[id] = group
  return ready
}

private func unavailableCandidate(_ error: any Error, provider: String) -> Bool {
  if let auth = error as? ChatGPTAuthError, case .loginRequired = auth { return true }
  if credentialLoginRefusal(error, provider: provider) { return true }
  switch InferenceError.normalize(error) {
  case .rateLimited, .authenticationRefused: return true
  default: return false
  }
}

private func resolvedPlacement(_ held: SessionModelRoute, session: SessionID, catalog: ProviderCatalog, usage: UsageBoard) async throws -> (SessionModelRoute, ResolvedModel)? {
  guard let id = held.group else { throw CatalogError.modelRouteInvalid(group: "<direct>", member: "<missing>") }
  var ready = try await placementCatalog(held, catalog: catalog)
  while true {
    let next = try replacementRoute(held, catalog: ready, usage: usage, reason: .compaction)
    guard next.member != held.member else { return nil }
    do {
      let resolved = try await ready.resolve(next.specifier, session: session, routeEpoch: next.epoch)
      return (next, resolved)
    } catch {
      guard unavailableCandidate(error, provider: next.specifier.provider) else { throw error }
      guard var group = ready.document.groups[id] else { throw CatalogError.modelRouteInvalid(group: id, member: held.member ?? "<missing>") }
      group.members.removeAll { $0.id == next.member }
      guard !group.members.isEmpty else { throw CatalogError.noUsableMembers(id) }
      ready.document.groups[id] = group
    }
  }
}

func compactionPlacement(owner: any Main, catalog: @escaping @Sendable (SessionID) async throws -> ProviderCatalog, usage: UsageBoard) -> @Sendable (SessionID, Transcript, CompactionTarget?) async throws -> ModelRouteTransition? {
  { id, transcript, target in
    if let target { return try await requestedTransition(target, session: id, transcript: transcript, owner: owner, catalog: catalog(id), usage: usage) }
    guard let held = try await owner.modelRoute(id), let group = held.group else { return nil }
    let catalog = try await catalog(id)
    _ = try catalog.validateRoute(held, group: group, effort: held.specifier.effort)
    guard let definition = catalog.document.groups[group], case .quotaAware = definition.policy else { return nil }
    guard let (next, resolved) = try await resolvedPlacement(held, session: id, catalog: catalog, usage: usage) else { return nil }
    var portable = try compactedHandoff(transcript, to: next, resolved: resolved)
    portable.appendRouteNotice(group: group, from: held.member!, to: next.member!, reason: next.reason)
    guard portable.estimatedContextTokens(images: resolved.budget.images) <= resolved.budget.usableTokens else { throw PortableHandoffError.modelHandoffTooLarge }
    return .init(expectedEpoch: held.epoch, route: next, transcript: portable)
  }
}

// The compacted generation projected onto a new binding, keeping the summary
// and pre-reads the compaction produced.
private func compactedHandoff(_ transcript: Transcript, to next: SessionModelRoute, resolved: ResolvedModel) throws -> Transcript {
  guard case let .generationHead(source)? = transcript.items.first else { throw PortableHandoffError.missingGenerationHead }
  var portable = try transcript.portableHandoff(binding: .init(identity: resolved.bindingIdentity, epoch: next.epoch), budget: resolved.budget, runningWork: source.runningWork ?? [])
  guard case var .generationHead(head) = portable.items[0] else { preconditionFailure("portable handoff must start a generation") }
  head.summary = source.summary
  head.snapshot = source.snapshot
  portable.items[0] = .generationHead(head)
  return portable
}

struct CompactionTargetRefused: Error, CustomStringConvertible {
  var description: String
}

/// The switch a `compact` call asked for. `provider/model` binds the session
/// to that model (leaving any group); a group id places within that group
/// (re-placing when it is the session's own). An exact group id wins over the
/// provider/model reading, so a group id may itself contain a slash. The target is checked against
/// the catalog and credential readiness before anything folds; a throw is the
/// tool's refusal. Nil when the target is where the session already is.
func requestedTransition(_ target: CompactionTarget, session id: SessionID, transcript: Transcript, owner: any Main, catalog: ProviderCatalog, usage: UsageBoard) async throws -> ModelRouteTransition? {
  guard let held = try await owner.modelRoute(id) else { throw CompactionTargetRefused(description: "this session has no model route yet") }
  let name = target.model.trimmingCharacters(in: .whitespacesAndNewlines)
  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid
  let next: SessionModelRoute
  let resolved: ResolvedModel
  if catalog.document.groups[name] == nil, catalog.document.groupErrors[name] == nil, let slash = name.firstIndex(of: "/") {
    let provider = String(name[..<slash])
    let model = String(name[name.index(after: slash)...])
    let sameModel = held.specifier.provider == provider && held.specifier.model == model
    let specifier = if let effort = target.effort ?? (sameModel ? held.specifier.effort : nil) {
      ModelSpecifier(provider: provider, model: model, effort: effort)
    } else {
      try catalog.defaultSpecifier(provider: provider, model: model)
    }
    try await catalog.validateReadiness(specifier)
    if held.group == nil, sameModel {
      return specifier == held.specifier ? nil : effortOnly(held, effort: specifier.effort, transcript: transcript)
    }
    next = SessionModelRoute(group: nil, member: nil, specifier: specifier, bindingFingerprint: catalog.document.providers[provider]!.routeFingerprint, epoch: uuid().uuidString.lowercased(), reason: .compaction, placedAt: now, evidence: [])
    resolved = try await catalog.resolve(specifier, session: id, routeEpoch: next.epoch)
  } else {
    let effort = try catalog.validateGroup(name, effort: target.effort ?? (held.group == name ? held.specifier.effort : nil))
    var seed = held
    seed.group = name
    seed.specifier.effort = effort
    if held.group != name { seed.member = nil }
    guard let (placed, model) = try await resolvedPlacement(seed, session: id, catalog: catalog, usage: usage) else {
      return effort == held.specifier.effort ? nil : effortOnly(held, effort: effort, transcript: transcript)
    }
    next = placed
    resolved = model
  }
  var portable = try compactedHandoff(transcript, to: next, resolved: resolved)
  if let group = next.group, group == held.group {
    portable.appendRouteNotice(group: group, from: held.member!, to: next.member!, reason: next.reason)
  } else {
    portable.appendRequestedSwitchNotice(from: routeLabel(held), to: routeLabel(next))
  }
  guard portable.estimatedContextTokens(images: resolved.budget.images) <= resolved.budget.usableTokens else { throw PortableHandoffError.modelHandoffTooLarge }
  return .init(expectedEpoch: held.epoch, route: next, transcript: portable)
}

// Same model, same account: the compacted transcript replays as it is and
// only the effort on the held route changes.
private func effortOnly(_ held: SessionModelRoute, effort: String, transcript: Transcript) -> ModelRouteTransition {
  var route = held
  route.specifier.effort = effort
  route.failure = nil
  return .init(expectedEpoch: held.epoch, route: route, transcript: transcript)
}

private func routeLabel(_ route: SessionModelRoute) -> String {
  if let group = route.group, let member = route.member { return "\(group):\(member)" }
  return "\(route.specifier.provider)/\(route.specifier.model)"
}

func recordRouteFailure(_ error: any Error, session: SessionID, owner: any Main, catalog: ProviderCatalog, usage: UsageBoard? = nil, inferenceStarted: Bool = true) async throws -> ModelRouteFailure? {
  guard let route = try await owner.modelRoute(session), let group = route.group, let definition = catalog.document.groups[group], case .quotaAware = definition.policy else { return nil }
  if !inferenceStarted, !credentialLoginRefusal(error, provider: route.specifier.provider) { return nil }
  let reason: ModelRouteFailure.Reason
  let retryAt: Date?
  var source = ModelRouteFailure.Source.upstream
  let code: String
  @Dependency(\.date.now) var now
  switch InferenceError.normalize(error) {
  case let .rateLimited(reset):
    reason = .quota
    let board = usage?.usage(route.specifier.provider, at: now)?.windows.filter { ($0.usedPercent ?? 0) >= 100 }.compactMap(\.resetsAt).max().map { Date(timeIntervalSince1970: $0) }
    retryAt = [reset, board].lazy.compactMap { $0 }.first { $0 > now }
    code = "quotaExhausted"
  case let .credentialRefreshRefused(id) where id == route.specifier.provider:
    reason = .authentication; retryAt = nil; code = "loginRequired"; source = .credentialRefresh
  case let .authenticationRefused(refusal): reason = .authentication; retryAt = nil; code = refusal
  case let .upstreamUnavailable(refusal): reason = .upstreamOutage; retryAt = now.addingTimeInterval(60); code = refusal
  case let .transient(status, _) where status.map({ (500 ..< 600).contains($0) }) == true: reason = .upstreamOutage; retryAt = now.addingTimeInterval(60); code = "upstreamUnavailable"
  case .transport(.connectTimeout): reason = .upstreamOutage; retryAt = now.addingTimeInterval(60); code = "upstreamUnavailable"
  default:
    guard credentialLoginRefusal(error, provider: route.specifier.provider) else { return nil }
    reason = .authentication; retryAt = nil; code = "loginRequired"; source = .credentialRefresh
  }
  let old = route.failure
  let failure = ModelRouteFailure(reason: reason, firstFailureAt: old?.firstFailureAt ?? now, retryAt: retryAt, consecutiveFailures: (old?.consecutiveFailures ?? 0) + 1, source: source, code: code, lastFailureAt: now)
  _ = try await owner.append(session, .modelRouteFailureUpdated(expectedEpoch: route.epoch, failure: failure))
  return failure
}

private func credentialLoginRefusal(_ error: any Error, provider: String) -> Bool {
  if let error = error as? InferenceError, case let .credentialRefreshRefused(id) = error { return id == provider }
  guard let error = error as? CatalogError else { return false }
  switch error {
  case let .credentialLoginRequired(id): return id == provider
  case let .groupMember(_, _, reason): return credentialLoginRefusal(reason, provider: provider)
  default: return false
  }
}
