import DeterministicDependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import SessionDomain
import Testing

@Suite(.deterministicDependencies) struct BenchmarkCatalogTests {
  @Test func benchmarkModelsSupportTheirDeclaredEfforts() throws {
    let file = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("SystemFiles/Benchmark/models.json")
    let document = try ModelsDocument(json: Data(contentsOf: file))
    let catalog = ProviderCatalog(document: document, credentials: .unavailable)
    #expect(!document.providers.isEmpty)
    for (providerID, provider) in document.providers {
      #expect(!provider.models.isEmpty)
      for (modelID, model) in provider.models {
        try catalog.validate(ModelSpecifier(provider: providerID, model: modelID, effort: model.defaultEffort))
        for effort in model.efforts {
          try catalog.validate(ModelSpecifier(provider: providerID, model: modelID, effort: effort))
        }
      }
    }
  }
}
