import Credentials
import Foundation
import InferenceKit
import SessionDomain
import Testing

struct UsageSourceTests {
  private let specifier = ModelSpecifier(provider: "openai", model: "gpt-5.4", effort: "medium")

  private func gatewayDocument() throws -> ModelsDocument {
    var document = try ModelsDocument(json: fixtureJSON)
    document.providers["openai"]!.usage = .gateway
    return document
  }

  @Test func aGatewayReadRoundTrips() throws {
    let document = try gatewayDocument()
    #expect(try ModelsDocument(json: JSONEncoder().encode(document)) == document)
  }

  @Test func aResponsesProviderWithAStoredCredentialDeclaresIt() throws {
    try ProviderCatalog(document: gatewayDocument(), credentials: .unavailable).validate(specifier)
  }

  @Test func anotherDialectCannotDeclareIt() throws {
    var document = try gatewayDocument()
    document.providers["openai"]!.dialect = .anthropic
    #expect(throws: CatalogError.invalidUsageSource(provider: "openai")) { try ProviderCatalog(document: document, credentials: .unavailable).validate(specifier) }
  }

  @Test func anOIDCProviderCannotDeclareIt() throws {
    var document = try gatewayDocument()
    document.providers["openai"]!.auth = .oidc
    #expect(throws: CatalogError.invalidUsageSource(provider: "openai")) { try ProviderCatalog(document: document, credentials: .unavailable).validate(specifier) }
  }

  @Test func anUnknownSourceInvalidatesOnlyItsProvider() throws {
    let encoded = try String(decoding: JSONEncoder().encode(gatewayDocument()), as: UTF8.self)
    let unknown = try ModelsDocument(json: Data(encoded.replacingOccurrences(of: #""usage":"gateway""#, with: #""usage":"probe""#).utf8))
    #expect(unknown.providerErrors.keys.sorted() == ["openai"])
  }
}
