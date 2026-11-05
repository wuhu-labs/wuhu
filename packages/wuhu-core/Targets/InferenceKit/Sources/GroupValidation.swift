import ModelProviders
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.SessionModelRoute

extension ProviderCatalog {
  public func validateGroup(_ id: String, effort: String? = nil) throws(CatalogError) -> String {
    try document.validateGroup(id, effort: effort)
  }

  public func validatedGroup(_ id: String, effort: String? = nil) throws(CatalogError) -> (declaration: ModelsDocument.Group, memberErrors: [String: CatalogError]) {
    try document.validatedGroup(id, effort: effort)
  }

  public func validateGroupReadiness(_ id: String, effort: String? = nil) async throws -> String {
    try await document.validateGroupReadiness(id, effort: effort) { member, effort in
      try await validateReadiness(.init(provider: member.provider, model: member.model, effort: effort))
    }
  }

  public func validateReadiness(_ specifier: ModelSpecifier) async throws {
    _ = try validate(specifier)
    let provider = document.providers[specifier.provider]!
    if provider.auth == .oidc {
      guard oidcToken != nil else { throw CatalogError.oidcNotConfigured(provider: specifier.provider) }
      do { try await oidcReadiness?(provider.baseURL) }
      catch { throw CatalogError.oidcNotConfigured(provider: specifier.provider) }
      return
    }
    guard let credential = try await credentials.resolve(specifier.provider) else {
      throw CatalogError.missingCredential(provider: specifier.provider)
    }
    switch (provider.dialect, credential) {
    case let (.codex, .chatGPT(token, account)):
      guard !token.isEmpty, !account.isEmpty else { throw CatalogError.missingCredential(provider: specifier.provider) }
    case let (.responses, .apiKey(key)), let (.anthropic, .apiKey(key)):
      guard !key.isEmpty else { throw CatalogError.missingCredential(provider: specifier.provider) }
    default: throw CatalogError.credentialMismatch(provider: specifier.provider)
    }
  }

  public func validateRoute(_ route: SessionModelRoute, group id: String, effort: String) throws -> ModelSpecifier {
    guard route.group == id, route.specifier.effort == effort,
          let member = document.groups[id]?.members.first(where: { $0.id == route.member }),
          member.provider == route.specifier.provider, member.model == route.specifier.model,
          document.providers[member.provider]?.routeFingerprint == route.bindingFingerprint
    else {
      throw CatalogError.modelRouteInvalid(group: id, member: route.member ?? "<missing>")
    }
    _ = try validateGroup(id, effort: effort)
    _ = try validate(route.specifier)
    return route.specifier
  }
}

extension ProviderCatalog {
  public var providerErrors: [String: CatalogError] {
    var errors = document.providerErrors
    for (id, provider) in document.providers {
      do {
        try provider.validateCapacity(providerID: id)
        try provider.validateConfiguration(providerID: id)
        for (name, model) in provider.models.sorted(by: { $0.key < $1.key }) {
          _ = try validate(.init(provider: id, model: name, effort: model.defaultEffort))
        }
      } catch { errors[id] = error }
    }
    return errors
  }

  public var groupMemberErrors: [String: [String: CatalogError]] {
    document.groupMemberErrors
  }

  public var groupErrors: [String: CatalogError] {
    document.invalidGroups
  }
}
