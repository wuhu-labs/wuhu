import Crypto
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension ModelsDocument {
  /// A nil `effort` is the model's default.
  public func validated(provider providerID: String, model name: String, effort: String?) throws(CatalogError) -> (provider: Provider, model: Model) {
    if let error = providerErrors[providerID] { throw error }
    if groupErrors[providerID] != nil || groups[providerID] != nil { throw CatalogError.unsupportedTarget(providerID) }
    guard let provider = providers[providerID] else {
      throw CatalogError.unknownProvider(providerID)
    }
    try provider.validateCapacity(providerID: providerID)
    try provider.validateConfiguration(providerID: providerID)
    guard let model = provider.models[name] else {
      throw CatalogError.unknownModel(provider: providerID, model: name)
    }
    guard model.maxInput > 0, model.maxOutput > 0, model.maxOutput < model.maxInput,
          (model.headroomOverride ?? model.maxOutput) >= 0,
          (model.headroomOverride ?? model.maxOutput) < model.maxInput,
          model.efforts.contains(model.defaultEffort)
    else {
      throw CatalogError.invalidModel(provider: providerID, model: name)
    }
    if let effort, !model.efforts.contains(effort) {
      throw CatalogError.unknownEffort(provider: providerID, model: name, effort: effort)
    }
    return (provider, model)
  }
}

extension ModelsDocument.Provider {
  public func validateCapacity(providerID: String) throws(CatalogError) {
    let binding = Set(models.values.flatMap(\.bindingWindows))
    for (window, size) in capacity ?? [:] {
      guard !window.isEmpty, binding.contains(window), size.isFinite, size > 0 else {
        throw CatalogError.invalidCapacity(provider: providerID, window: window)
      }
    }
  }

  public var routeFingerprint: String {
    let binding = [dialect.rawValue, baseURL.absoluteString, transport?.rawValue ?? "sse", auth?.rawValue ?? "credential", originator ?? "wuhu"].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return SHA256.hash(data: Data(binding.utf8)).map { ("0" + String($0, radix: 16)).suffix(2) }.joined()
  }
}
