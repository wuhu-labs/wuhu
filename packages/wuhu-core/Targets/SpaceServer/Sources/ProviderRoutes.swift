import Dependencies
import Fetch
import InferenceKit
import JSONValue
import Serve
import ServeRouting
import struct SpaceContract.CatalogEntryError
import struct SpaceContract.ModelGroupDescriptor
import struct SpaceContract.ModelGroupMember
import struct SpaceContract.ProviderDescriptor
import struct SpaceContract.ProviderModel
import struct SpaceContract.ProvidersOutput
import SpaceCore

func addProviderRoutes(_ router: inout Router, space: Space, usage: UsageBoard?) {
  router.get("/v1/providers") { _, _ in
    let document: ModelsDocument
    do {
      document = try await readModelsDocument(space: space)
    } catch SpaceError.notFound {
      document = ModelsDocument(providers: [:])
    } catch { return sessionErrorResponse(error) }
    @Dependency(\.date.now) var now
    let providers = document.providers.sorted { $0.key < $1.key }.map { id, provider in
      ProviderDescriptor(
        id: id,
        dialect: provider.dialect.rawValue,
        models: provider.models.sorted { $0.key < $1.key }.map { name, model in
          ProviderModel(id: name, effortLevels: model.efforts, defaultEffort: model.defaultEffort)
        },
        usage: usage?.usage(id, at: now),
      )
    }
    let catalog = ProviderCatalog(document: document, credentials: .unavailable)
    let groupErrors = catalog.groupErrors
    let groups = try document.groups.sorted { $0.key < $1.key }.filter { groupErrors[$0.key] == nil }.map { id, group in
      let validated = try catalog.validatedGroup(id)
      let validMembers = validated.declaration.members
      let efforts = validMembers.map { Set(document.providers[$0.provider]!.models[$0.model]!.efforts) }
        .reduce(Set(document.providers[validMembers[0].provider]!.models[validMembers[0].model]!.efforts)) { $0.intersection($1) }
      return ModelGroupDescriptor(
        id: id,
        members: group.members.map { ModelGroupMember(id: $0.id, provider: $0.provider, model: $0.model) },
        defaultEffort: group.defaultEffort,
        effortLevels: efforts.sorted(),
        policy: try JSONValueEncoder().encode(group.policy),
        memberErrors: validated.memberErrors.sorted(by: { $0.key < $1.key }).map { CatalogEntryError(id: $0.key, message: $0.value.description) },
      )
    }
    return try Response.json(ProvidersOutput(providers: providers, groups: groups.isEmpty ? nil : groups, providerErrors: catalog.providerErrors.sorted(by: { $0.key < $1.key }).map { CatalogEntryError(id: $0.key, message: $0.value.description) }, groupErrors: groupErrors.sorted(by: { $0.key < $1.key }).map { CatalogEntryError(id: $0.key, message: $0.value.description) }))
  }
}

func modelsDocument(space: Space) async -> ModelsDocument? {
  try? await readModelsDocument(space: space)
}
