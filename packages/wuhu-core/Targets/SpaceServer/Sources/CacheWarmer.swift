import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import InferenceKit
import Logging
import SessionDomain
import SpaceCore

struct CacheWarmer: Sendable {
  let space: Space
  let usage: UsageBoard

  func run() async {
    @Dependency(\.continuousClock) var clock
    do {
      try await space.sessions.deferOverdueCacheWarming()
      while !Task.isCancelled {
        await tick()
        try await clock.sleep(for: .seconds(60))
      }
    } catch is CancellationError {
    } catch {
      Logger(label: "wuhu.cache-warmer").error("cache warmer stopped", metadata: ["error": "\(error)"])
    }
  }

  func tick() async {
    do {
      for id in try await space.sessions.cacheWarmingAgents() {
        do {
          let record = try await space.sessions.record(id)
          guard record.work == .noWork, record.hold == .normal,
                let (model, provider, entry) = try await configuration(record),
                let policy = entry.cacheWarming else { continue }
          let transcript = try await space.sessions.transcript(id)
          guard case .assistant? = transcript.items.last else { continue }
          try await space.sessions.scheduleCacheWarming(id, intervalSeconds: policy.intervalSeconds)
          try await space.sessions.enqueueCacheWarming(
            id, maxPings: policy.maxPings,
            contextTokens: transcript.estimatedContextTokens(images: entry.budget(provider.dialect).images),
            offerThreshold: policy.compactionThresholdTokens, offerGrowth: policy.compactionGrowthTokens,
            quotaLow: quotaLow(provider: model.provider, policy: policy),
          )
        } catch {
          Logger(label: "wuhu.cache-warmer").error("cache warming failed", metadata: ["session": "\(id.rawValue)", "error": "\(error)"])
        }
      }
    } catch {
      Logger(label: "wuhu.cache-warmer").error("cache warming catalog unavailable", metadata: ["error": "\(error)"])
    }
  }

  func allows(_ id: SessionID) async throws -> Bool {
    let record = try await space.sessions.record(id)
    guard record.kind == .agent, record.lifecycle == .live, record.hold == .normal, let (model, _, entry) = try await configuration(record) else { return false }
    guard let policy = entry.cacheWarming else { return false }
    return !quotaLow(provider: model.provider, policy: policy)
  }

  private func configuration(_ record: SessionRecord) async throws -> (ModelSpecifier, ModelsDocument.Provider, ModelsDocument.Model)? {
    let document: ModelsDocument
    let model: ModelSpecifier
    switch record.executor {
    case let .kernel(specifier):
      document = try await readModelsDocument(space: space, includeGroups: false)
      model = specifier
    case let .modelGroup(id, effort):
      document = try await readModelsDocument(space: space)
      guard let route = try await space.sessions.modelRoute(record.id) else {
        throw CatalogError.modelRouteInvalid(group: id, member: "<missing>")
      }
      model = try ProviderCatalog(document: document, credentials: .unavailable).validateRoute(route, group: id, effort: effort)
    case .claudeCode, .contractor: return nil
    }
    @Dependency(\.date.now) var now
    if let failure = try await space.sessions.modelRoute(record.id)?.failure, !failure.refusing, failure.evidenceExpiresAt > now { return nil }
    if try await space.sessions.modelProviderRefusing(provider: model.provider, model: model.model) { return nil }
    let entry = try ProviderCatalog(document: document, credentials: .unavailable).validate(model)
    return (model, document.providers[model.provider]!, entry)
  }

  func quotaLow(provider: String, policy: CacheWarmingPolicy) -> Bool {
    @Dependency(\.date) var date
    guard let window = usage.usage(provider)?.windows.first(where: { $0.name == "five_hour" }),
          let used = window.usedPercent, used.isFinite,
          window.resetsAt.map({ $0 > date.now.timeIntervalSince1970 }) ?? true else { return false }
    return 100 - used <= policy.minimumRemainingPercent
  }
}
