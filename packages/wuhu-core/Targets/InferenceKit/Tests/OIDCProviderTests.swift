import Credentials
import Dependencies
import Fetch
import Foundation
@testable import InferenceKit
import JSONValue
import Scratch
import SessionDomain
import Testing
import WuhuAI

@Suite struct OIDCProviderTests {
  @Test(arguments: ["anthropic", "deepseek", "openai"])
  func bearerAuthMintsPerCallWithoutCredentials(provider: String) async throws {
    let minted = TokenCalls()
    let catalog = try catalog(provider: provider, signer: { url, session in await minted.mint(url, session) })
    let specifier = try catalog.defaultSpecifier(provider: provider, model: provider == "openai" ? "gpt-5.4" : provider == "deepseek" ? "deepseek-v4-pro" : "claude-sonnet-5")
    for index in 1 ... 2 {
      let resolved = try await catalog.resolve(specifier, session: .init("blue-fox-tree"))
      let fetch = FetchClient { request in
        #expect(request.headers.sensitiveValues["authorization"] == "Bearer oidc-fixture-\(index)")
        #expect(request.headers["x-api-key"] == nil)
        #expect(request.headers.sensitiveValues["x-api-key"] == nil)
        return Response(status: .unauthorized, body: .string("offline rejection"))
      }
      await withDependencies { $0.fetch = fetch } operation: {
        for await _ in resolved.endpoint.runInference(context: .init(messages: []), options: .init(), mediaResolver: nil) {}
      }
    }
    #expect(await minted.count == 2)
    #expect(await minted.session == "blue-fox-tree")
    #expect(await minted.url == catalog.document.providers[provider]?.baseURL)
  }

  @Test func signingErrorIsTypedAndDoesNotExposeSecrets() async throws {
    struct SecretError: Error, CustomStringConvertible { var description: String { "private-key-do-not-print" } }
    let catalog = try catalog(provider: "openai", signer: { _, _ in throw SecretError() })
    let spec = try catalog.defaultSpecifier(provider: "openai", model: "gpt-5.4")
    await #expect(throws: InferenceError.other(status: nil, body: nil)) {
      try await catalog.resolve(spec, session: .init("s"))
    }
  }

  @Test func signerCancellationRemainsCancelled() async throws {
    let catalog = try catalog(provider: "openai", signer: { _, _ in throw CancellationError() })
    await #expect(throws: InferenceError.cancelled) {
      try await catalog.resolve(.init(provider: "openai", model: "gpt-5.4", effort: "high"), session: .init("s"))
    }
  }

  @Test(arguments: ["OIDC token audience is invalid; check the provider baseURL.", "OIDC token issuer is invalid; check HTTPS --origin."])
  func signerConfigurationErrorsKeepTheirPreciseHints(hint: String) async throws {
    let failure = InferenceError.invalidInput(status: 422, body: hint)
    let catalog = try catalog(provider: "openai", signer: { _, _ in throw failure })
    await #expect(throws: failure) {
      try await catalog.resolve(.init(provider: "openai", model: "gpt-5.4", effort: "high"), session: .init("s"))
    }
  }

  @Test func noSignerNeverDetoursToCredential() async throws {
    let catalog = try catalog(provider: "openai", signer: nil)
    await #expect(throws: InferenceError.invalidInput(status: 422, body: "OIDC authentication is not configured on this server.")) {
      try await catalog.resolve(.init(provider: "openai", model: "gpt-5.4", effort: "high"), session: .init("s"))
    }
  }

  @Test func codexOIDCIsRejectedBeforeAnyAuth() async throws {
    let catalog = try catalog(provider: "codex", signer: { _, _ in Issue.record("must not sign"); return "wrong" })
    #expect(throws: CatalogError.invalidOIDCDialect(provider: "codex")) {
      try catalog.validate(.init(provider: "codex", model: "gpt-5.6-sol", effort: "low"))
    }
  }

  @Test func oidcFieldRoundTripsAndUnknownAuthIsRejected() throws {
    let catalog = try catalog(provider: "openai", signer: nil)
    #expect(try ModelsDocument(json: JSONEncoder().encode(catalog.document)) == catalog.document)
    var json = try #require(String(data: JSONEncoder().encode(catalog.document), encoding: .utf8))
    json = json.replacingOccurrences(of: "oidc", with: "unsupported")
    #expect(throws: (any Error).self) { try ModelsDocument(json: Data(json.utf8)) }
  }

  @Test func bearerNeverAppearsInAttemptLog() async throws {
    let directory = try scratchURL("oidc-attempt-log")
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = try catalog(provider: "anthropic", signer: { _, _ in "do-not-log-jwt" })
    let model = try await catalog.resolve(.init(provider: "anthropic", model: "claude-sonnet-5", effort: "high"), session: .init("s"))
    let executor = InferenceExecutor(session: .init("s"), model: model, systemPrompt: "offline", tools: [], log: .init(directory: directory))
    await withDependencies { $0.fetch = FetchClient { _ in Response(status: .unauthorized, body: .string("offline rejection")) } } operation: {
      do { _ = try await executor.run(attemptID: UUID(0), transcript: .init(), mode: .normal) }
      catch {}
    }
    let log = try String(contentsOf: directory.appendingPathComponent("\(UUID(0).uuidString.lowercased()).log"), encoding: .utf8)
    #expect(!log.contains("do-not-log-jwt"))
    #expect(!log.contains("authorization"))
  }
}

private func catalog(provider: String, signer: (@Sendable (URL, SessionID) async throws -> String)?) throws -> ProviderCatalog {
  var document = try ModelsDocument(json: fixtureJSON)
  document.providers[provider]?.auth = .oidc
  return ProviderCatalog(document: document, credentials: .init { _ in
    Issue.record("OIDC must never resolve a stored credential")
    return .apiKey("stored-key-do-not-use")
  }, oidcToken: signer)
}

private actor TokenCalls {
  var count = 0
  var session: String?
  var url: URL?
  func mint(_ url: URL, _ session: SessionID) -> String {
    count += 1
    self.url = url
    self.session = session.rawValue
    return "oidc-fixture-\(count)"
  }
}
