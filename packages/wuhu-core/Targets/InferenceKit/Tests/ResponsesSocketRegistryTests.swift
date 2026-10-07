import Clocks
import Credentials
import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
@testable import InferenceKit
import SessionDomain
import Testing
import WuhuAI

@Suite struct ResponsesSocketRegistryTests {
  private func model(key: String = "offline", url: String = "https://example.test/v1") async throws -> ResolvedModel {
    var document = try ModelsDocument(json: fixtureJSON)
    document.providers["openai"]?.transport = .websocket
    document.providers["openai"]?.baseURL = URL(string: url)!
    return try await ProviderCatalog(document: document, credentials: .init { _ in .apiKey(key) }).resolve(.init(provider: "openai", model: "gpt-5.4", effort: "medium"), session: .init("one"))
  }

  @Test func configurationDefaultsAndInvalidDialectsFailClosed() async throws {
    let document = try ModelsDocument(json: fixtureJSON)
    #expect(document.providers["openai"]?.transport == nil)
    let resolved = try await fixtureCatalog().resolve(.init(provider: "openai", model: "gpt-5.4", effort: "medium"), session: .init("one"))
    #expect(resolved.transport == .sse)
    for dialect in [ModelsDocument.Dialect.anthropic, .claude] {
      var invalid = document
      invalid.providers["openai"]?.dialect = dialect
      invalid.providers["openai"]?.transport = .websocket
      let bytes = try JSONEncoder().encode(invalid)
      #expect(throws: CatalogError.invalidTransport(provider: "openai")) { _ = try ModelsDocument(json: bytes) }
      #expect(throws: CatalogError.invalidTransport(provider: "openai")) { try ProviderCatalog(document: invalid, credentials: .unavailable).validate(.init(provider: "openai", model: "gpt-5.4", effort: "medium")) }
    }
    let malformed = String(decoding: fixtureJSON, as: UTF8.self).replacingOccurrences(of: "\"dialect\": \"responses\",", with: "\"dialect\": \"responses\", \"transport\":\"unknown\",")
    #expect(throws: (any Error).self) { _ = try ModelsDocument(json: Data(malformed.utf8)) }
    let ws = try await model()
    #expect(ws.transport == .websocket)
  }

  @Test func ownershipExclusionCredentialAndConfigurationRotation() async throws {
    let registry = ResponsesSocketRegistry()
    let model = try await model()
    let first = try await registry.acquire(session: .init("one"), model: model)
    await #expect(throws: InferenceError.self) { _ = try await registry.acquire(session: .init("one"), model: model) }
    let other = try await registry.acquire(session: .init("two"), model: model)
    #expect(first.session !== other.session)
    await registry.release(session: .init("one"), lease: first.lease)
    let reuse = try await registry.acquire(session: .init("one"), model: model)
    #expect(reuse.session === first.session)
    await registry.release(session: .init("one"), lease: first.lease)
    await registry.invalidate(.init("one"), lease: first.lease)
    await #expect(throws: InferenceError.self) { _ = try await registry.acquire(session: .init("one"), model: model) }
    await registry.release(session: .init("one"), lease: reuse.lease)
    let changed = try await registry.acquire(session: .init("one"), model: self.model(key: "new-offline"))
    #expect(changed.session !== first.session)
    await registry.release(session: .init("one"), lease: changed.lease)
    let redirected = try await registry.acquire(session: .init("one"), model: self.model(key: "new-offline", url: "https://other.test/v1"))
    #expect(redirected.session !== changed.session)
    await registry.invalidate(.init("one"))
    let fresh = try await registry.acquire(session: .init("one"), model: model)
    #expect(fresh.session !== redirected.session)
    await registry.shutdown()
  }

  @Test func boundedIdleTTLAndAgeNeverEvictActiveLease() async throws {
    let clock = TestClock()
    try await withDependencies { $0.continuousClock = clock } operation: {
      let registry = ResponsesSocketRegistry(idleTTL: .seconds(300), maxIdle: 1, maximumAge: .seconds(3300))
      let model = try await model()
      let first = try await registry.acquire(session: .init("one"), model: model)
      let active = try await registry.acquire(session: .init("active"), model: model)
      await registry.release(session: .init("one"), lease: first.lease)
      await clock.advance(by: .seconds(1))
      let second = try await registry.acquire(session: .init("two"), model: model)
      await registry.release(session: .init("two"), lease: second.lease)
      await registry.sweep()
      let replaced = try await registry.acquire(session: .init("one"), model: model)
      #expect(replaced.session !== first.session)
      await registry.release(session: .init("one"), lease: replaced.lease)
      await clock.advance(by: .seconds(300))
      await registry.sweep()
      let expired = try await registry.acquire(session: .init("two"), model: model)
      #expect(expired.session !== second.session)
      await clock.advance(by: .seconds(3300))
      await registry.sweep()
      await #expect(throws: InferenceError.self) { _ = try await registry.acquire(session: .init("active"), model: model) }
      await registry.release(session: .init("active"), lease: active.lease)
      let rotated = try await registry.acquire(session: .init("active"), model: model)
      #expect(rotated.session !== active.session)
      await registry.shutdown()
    }
  }
}
