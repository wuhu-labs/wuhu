import Fetch
import InferenceKit
import JSONValue
import Serve
import ServeRouting
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
    let providers = document.providers.sorted { $0.key < $1.key }.map { id, provider in
      ProviderDescriptor(
        id: id,
        dialect: provider.dialect.rawValue,
        models: provider.models.sorted { $0.key < $1.key }.map { name, model in
          ProviderModel(id: name, effortLevels: model.efforts, defaultEffort: model.defaultEffort)
        },
        usage: usage?.usage(id),
      )
    }
    let catalog = ProviderCatalog(document: document, credentials: .unavailable)
    let groups: [ModelGroupDescriptor]
    do {
      groups = try document.groups.sorted { $0.key < $1.key }.map { id, group in
        _ = try catalog.validateGroup(id)
        let efforts = group.members.map { Set(document.providers[$0.provider]!.models[$0.model]!.efforts) }
          .reduce(Set(document.providers[group.members[0].provider]!.models[group.members[0].model]!.efforts)) { $0.intersection($1) }
        return ModelGroupDescriptor(
          id: id,
          members: group.members.map { ModelGroupMember(id: $0.id, provider: $0.provider, model: $0.model) },
          defaultEffort: group.defaultEffort,
          effortLevels: efforts.sorted(),
          policy: try JSONValueEncoder().encode(group.policy),
        )
      }
    } catch { return sessionErrorResponse(error) }
    return try Response.json(ProvidersOutput(providers: providers, groups: groups.isEmpty ? nil : groups))
  }
}

func modelsDocument(space: Space) async -> ModelsDocument? {
  try? await readModelsDocument(space: space)
}
