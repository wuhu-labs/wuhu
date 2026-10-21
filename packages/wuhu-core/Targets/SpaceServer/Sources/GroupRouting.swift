import struct Credentials.CredentialResolver
import Dependencies
import protocol MainHub.Main
import SessionTools
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import SessionDomain
import SpaceCore

func modelGroupExecutorResolver(catalog: @escaping @Sendable () async throws -> ProviderCatalog) -> @Sendable (String, String?) async throws -> SessionExecutor {
  { id, effort in
    let effort = try await catalog().validateGroupReadiness(id, effort: effort)
    return .modelGroup(id: id, effort: effort)
  }
}

func modelRoutePreparer(catalog: @escaping @Sendable () async throws -> ProviderCatalog, usage: UsageBoard) -> @Sendable (SessionExecutor, ModelPlacementReason) async throws -> SessionModelRoute? {
  { executor, reason in
    guard case let .modelGroup(id, effort) = executor else { return nil }
    let catalog = try await catalog()
    _ = try await catalog.validateGroupReadiness(id, effort: effort)
    let group = catalog.document.groups[id]!
    let snapshots = groupUsage(group, usage: usage)
    @Dependency(\.date) var date
    @Dependency(\.uuid) var uuid
    let now = date.now
    let placement = try placeModelGroup(id: id, group: group, providers: catalog.document.providers, usage: snapshots, now: now, reason: reason)
    return SessionModelRoute(
      group: id,
      member: placement.member.id,
      specifier: ModelSpecifier(provider: placement.member.provider, model: placement.member.model, effort: effort),
      bindingFingerprint: catalog.document.providers[placement.member.provider]!.routeFingerprint,
      epoch: uuid().uuidString.lowercased(),
      reason: placement.reason,
      placedAt: now,
      evidence: placement.evidence,
    )
  }
}

func activeModelSpecifier(_ record: SessionRecord, store: SessionStore) async -> ModelSpecifier? {
  switch record.executor {
  case let .kernel(model), let .claudeCode(model): model
  case .modelGroup: try? await store.modelRoute(record.id)?.specifier
  case .contractor: nil
  }
}

func readModelsDocument(space: Space, includeGroups: Bool = true) async throws -> ModelsDocument {
  let fs = await space.fs(.shared)
  let data: Data
  do { data = try await fs.read(ModelsDocument.spacePath).1 }
  catch SpaceError.notFound { data = Data("{}".utf8) }
  guard includeGroups else { return try ModelsDocument(json: data) }
  let groups: Data?
  do { groups = try await fs.read(ModelsDocument.groupPath).1 }
  catch SpaceError.notFound { groups = nil }
  return try ModelsDocument(json: data, groupsJSON: groups)
}

// Main's own catalog for placing and validating routes: `/models.json` and
// `/model-groups.json` from `shared`, re-read per use (models are data in the
// space, edited at runtime), signed with `access`.
func groupCatalog(space: Space, access: InferenceAccess) -> @Sendable () async throws -> ProviderCatalog {
  {
    let fs = await space.fs(.shared)
    let data = try await fs.read(ModelsDocument.spacePath).1
    let groups: Data?
    do { groups = try await fs.read(ModelsDocument.groupPath).1 }
    catch SpaceError.notFound { groups = nil }
    return access.catalog(try ModelsDocument(json: data, groupsJSON: groups))
  }
}

func activeModelSpecifier(_ record: SessionRecord, owner: any Main) async -> ModelSpecifier? {
  switch record.executor {
  case let .kernel(model), let .claudeCode(model): model
  case .modelGroup: try? await owner.modelRoute(record.id)?.specifier
  case .contractor: nil
  }
}

func groupUsage(_ group: ModelsDocument.Group, usage: UsageBoard) -> [String: ModelUsageSnapshot] {
  Dictionary(uniqueKeysWithValues: Set(group.members.map(\.provider)).compactMap { provider -> (String, ModelUsageSnapshot)? in
    guard let held = usage.usage(provider) else { return nil }
    return (provider, ModelUsageSnapshot(observedAt: held.observedAt, windows: held.windows.map { .init(name: $0.name, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }))
  })
}
