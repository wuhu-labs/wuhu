import enum Credentials.ChatGPTAuthError
import Dependencies
import ExecutionOwner
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
  guard let id = held.group, let group = catalog.document.groups[id] else { throw CatalogError.modelRouteInvalid(group: held.group ?? "<direct>", member: held.member ?? "<missing>") }
  guard !group.members.isEmpty else { throw CatalogError.noUsableMembers(id) }
  @Dependency(\.date.now) var now
  @Dependency(\.uuid) var uuid
  let placed = try placeModelGroup(id: id, group: group, providers: catalog.document.providers, usage: groupUsage(group, usage: usage), now: now, reason: reason)
  return .init(group: id, member: placed.member.id, specifier: .init(provider: placed.member.provider, model: placed.member.model, effort: held.specifier.effort), bindingFingerprint: catalog.document.providers[placed.member.provider]!.routeFingerprint, epoch: uuid().uuidString.lowercased(), reason: reason, placedAt: now, evidence: placed.evidence)
}

private func placementCatalog(_ held: SessionModelRoute, catalog: ProviderCatalog, excludingHeld: Bool) async throws -> ProviderCatalog {
  guard let id = held.group, var group = catalog.document.groups[id] else { throw CatalogError.modelRouteInvalid(group: held.group ?? "<direct>", member: held.member ?? "<missing>") }
  _ = try catalog.validateGroup(id, effort: held.specifier.effort)
  var eligible: [ModelsDocument.Member] = []
  for member in group.members {
    do {
      try await catalog.validateReadiness(.init(provider: member.provider, model: member.model, effort: held.specifier.effort))
      if !excludingHeld || member.id != held.member { eligible.append(member) }
    } catch {
      if excludingHeld || member.id != held.member, unavailableCandidate(error, provider: member.provider) { continue }
      if let reason = error as? CatalogError { throw CatalogError.groupMember(group: id, member: member.id, reason: reason) }
      if let auth = error as? ChatGPTAuthError, case .loginRequired = auth { throw CatalogError.groupMember(group: id, member: member.id, reason: .credentialLoginRequired(provider: member.provider)) }
      throw error
    }
  }
  guard !eligible.isEmpty else { throw CatalogError.noUsableMembers(id) }
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

private func resolvedPlacement(_ held: SessionModelRoute, session: SessionID, catalog: ProviderCatalog, usage: UsageBoard, excludingHeld: Bool) async throws -> (SessionModelRoute, ResolvedModel)? {
  guard let id = held.group else { throw CatalogError.modelRouteInvalid(group: "<direct>", member: "<missing>") }
  var ready = try await placementCatalog(held, catalog: catalog, excludingHeld: excludingHeld)
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

func compactionPlacement(owner: any ExecutionOwnerClient, catalog: @escaping @Sendable () async throws -> ProviderCatalog, usage: UsageBoard) -> @Sendable (SessionID, Transcript) async throws -> ModelRouteTransition? {
  { id, transcript in
    guard let held = try await owner.modelRoute(id), let group = held.group else { return nil }
    let catalog = try await catalog()
    _ = try catalog.validateRoute(held, group: group, effort: held.specifier.effort)
    guard let definition = catalog.document.groups[group], case .quotaAware = definition.policy else { return nil }
    guard let (next, resolved) = try await resolvedPlacement(held, session: id, catalog: catalog, usage: usage, excludingHeld: false) else { return nil }
    var portable = try transcript.portableHandoff(binding: .init(identity: resolved.bindingIdentity, epoch: next.epoch), budget: resolved.budget)
    if case let .generationHead(source)? = transcript.items.first, case var .generationHead(head) = portable.items[0] {
      head.summary = source.summary
      head.snapshot = source.snapshot
      portable.items[0] = .generationHead(head)
    }
    portable.appendRouteNotice(group: group, from: held.member!, to: next.member!, reason: next.decisionReason)
    guard portable.estimatedContextTokens(images: resolved.budget.images) <= resolved.budget.usableTokens else { throw PortableHandoffError.modelHandoffTooLarge }
    return .init(expectedEpoch: held.epoch, route: next, transcript: portable)
  }
}

func routeWaitOrSwitch(_ route: SessionModelRoute, session: SessionID, catalog: ProviderCatalog, usage: UsageBoard) async throws {
  guard let group = route.group, let definition = catalog.document.groups[group], case .quotaAware = definition.policy, let failure = route.failure, failure.refusing else { return }
  @Dependency(\.date.now) var now
  if failure.reason == .quota, let reset = failure.retryAt, reset < failure.deadline, reset <= now { return }
  if now >= failure.deadline {
    let next: SessionModelRoute
    let resolved: ResolvedModel
    do {
      guard let (prepared, model) = try await resolvedPlacement(route, session: session, catalog: catalog, usage: usage, excludingHeld: true) else { throw CatalogError.noUsableMembers(group) }
      var cause = prepared
      cause.switchCause = failure.reason
      next = cause
      resolved = model
    } catch CatalogError.noUsableMembers { throw ModelRouteWaiting(retryAt: max(now.addingTimeInterval(60), failure.retryAt ?? now)) }
    throw ReplayBoundaryRequired(binding: .init(identity: resolved.bindingIdentity, epoch: next.epoch), budget: resolved.budget, route: next, expectedEpoch: route.epoch)
  }
  switch failure.reason {
  case .authentication:
    throw ModelRouteWaiting(retryAt: failure.deadline)
  case .quota:
    if let reset = failure.retryAt, reset <= now { return }
    throw ModelRouteWaiting(retryAt: min(failure.retryAt ?? now.addingTimeInterval(60), failure.deadline))
  case .upstreamOutage:
    if let retry = failure.retryAt, retry > now { throw ModelRouteWaiting(retryAt: min(retry, failure.deadline)) }
  }
}

func recordRouteFailure(_ error: any Error, session: SessionID, owner: any ExecutionOwnerClient, catalog: ProviderCatalog, usage: UsageBoard? = nil, inferenceStarted: Bool = true) async throws -> ModelRouteFailure? {
  guard let route = try await owner.modelRoute(session), let group = route.group, let definition = catalog.document.groups[group], case let .quotaAware(seconds) = definition.policy else { return nil }
  if !inferenceStarted, !credentialLoginRefusal(error, provider: route.specifier.provider) { return nil }
  let reason: ModelRouteFailure.Reason
  let retryAt: Date?
  var source = ModelRouteFailure.Source.upstream
  let code: String
  @Dependency(\.date.now) var now
  switch InferenceError.normalize(error) {
  case let .rateLimited(reset):
    reason = .quota
    let reported = reset ?? usage?.usage(route.specifier.provider)?.windows.filter { ($0.usedPercent ?? 0) >= 100 }.compactMap(\.resetsAt).max().map { Date(timeIntervalSince1970: $0) }
    retryAt = reported.flatMap { $0 > now ? $0 : nil }
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
  let failure = ModelRouteFailure(reason: reason, firstFailureAt: old?.firstFailureAt ?? now, deadline: old?.deadline ?? now.addingTimeInterval(Double(seconds)), retryAt: retryAt, consecutiveFailures: (old?.consecutiveFailures ?? 0) + 1, source: source, code: code, lastFailureAt: now)
  try await owner.updateModelRouteFailure(session, expectedEpoch: route.epoch, failure: failure)
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
