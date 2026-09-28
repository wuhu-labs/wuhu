import Fetch
import struct InferenceKit.ModelsDocument
import Serve
import ServeRouting
import struct SpaceContract.ProviderDescriptor
import struct SpaceContract.ProviderModel
import struct SpaceContract.ProvidersOutput
import SpaceCore

func addProviderRoutes(_ router: inout Router, space: Space, usage: UsageBoard?) {
  router.get("/v1/providers") { _, _ in
    let document = await modelsDocument(space: space)
    let providers = (document?.providers ?? [:]).sorted { $0.key < $1.key }.map { id, provider in
      ProviderDescriptor(
        id: id,
        dialect: provider.dialect.rawValue,
        models: provider.models.sorted { $0.key < $1.key }.map { name, model in
          ProviderModel(id: name, effortLevels: model.efforts, defaultEffort: model.defaultEffort)
        },
        usage: usage?.usage(id),
      )
    }
    return try Response.json(ProvidersOutput(providers: providers))
  }
}

func modelsDocument(space: Space) async -> ModelsDocument? {
  guard let (_, data) = try? await space.fs(.shared).read(ModelsDocument.spacePath) else { return nil }
  return try? ModelsDocument(json: data)
}
