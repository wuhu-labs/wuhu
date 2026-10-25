import enum Credentials.ChatGPTAuthError
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.SessionModelRoute

extension ProviderCatalog {
  public func validateGroup(_ id: String, effort: String? = nil) throws(CatalogError) -> String {
    let group = try validatedGroup(id, effort: effort).declaration
    return effort ?? group.defaultEffort
  }

  public func validatedGroup(_ id: String, effort: String? = nil) throws(CatalogError) -> (declaration: ModelsDocument.Group, memberErrors: [String: CatalogError]) {
    if let error = document.groupErrors[id] { throw error }
    guard !id.isEmpty, var group = document.groups[id] else { throw .unknownGroup(id) }
    guard document.providerErrors[id] == nil, document.providers[id] == nil, !group.members.isEmpty else {
      throw .invalidGroup(group: id, reason: "group must have members and cannot also be a provider")
    }
    var ids: Set<String> = []
    var pairs: Set<ModelSpecifier> = []
    for member in group.members {
      guard !member.id.isEmpty, !member.provider.isEmpty, !member.model.isEmpty,
            ids.insert(member.id).inserted,
            pairs.insert(ModelSpecifier(provider: member.provider, model: member.model, effort: "")).inserted
      else {
        throw .groupMember(group: id, member: member.id, reason: .invalidGroup(group: id, reason: "empty or duplicate member id/provider/model pair"))
      }
    }
    switch group.policy {
    case let .quotaAware(seconds):
      guard (0 ... 86400).contains(seconds) else { throw .invalidGroup(group: id, reason: "holdDownSeconds must be 0...86400") }
    case let .select(member):
      guard ids.contains(member) else { throw .invalidGroup(group: id, reason: "select member \(member) does not exist") }
    }
    var errors: [String: CatalogError] = [:]
    for member in group.members {
      do {
        _ = try validate(.init(provider: member.provider, model: member.model, effort: group.defaultEffort))
        if let effort { _ = try validate(.init(provider: member.provider, model: member.model, effort: effort)) }
      } catch { errors[member.id] = .groupMember(group: id, member: member.id, reason: error) }
    }
    if case let .select(member) = group.policy, let error = errors[member] { throw error }
    let firstError = group.members.compactMap { errors[$0.id] }.first
    if let firstError, errors.count == group.members.count { throw firstError }
    group.members.removeAll { errors[$0.id] != nil }
    return (group, errors)
  }

  public func validateGroupReadiness(_ id: String, effort: String? = nil) async throws -> String {
    let effort = try validateGroup(id, effort: effort)
    for member in try validatedGroup(id, effort: effort).declaration.members {
      do {
        try await validateReadiness(.init(provider: member.provider, model: member.model, effort: effort))
      } catch ChatGPTAuthError.loginRequired {
        throw CatalogError.groupMember(group: id, member: member.id, reason: .credentialLoginRequired(provider: member.provider))
      } catch let error as CatalogError {
        throw CatalogError.groupMember(group: id, member: member.id, reason: error)
      } catch {
        throw CatalogError.groupMember(group: id, member: member.id, reason: .invalidGroup(group: id, reason: "credential readiness failed"))
      }
    }
    return effort
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

extension ModelsDocument.Provider {
  func validateCapacity(providerID: String) throws(CatalogError) {
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
    var errors: [String: [String: CatalogError]] = [:]
    for id in document.groups.keys {
      if let members = try? validatedGroup(id).memberErrors, !members.isEmpty { errors[id] = members }
    }
    return errors
  }

  public var groupErrors: [String: CatalogError] {
    var errors = document.groupErrors
    for id in document.groups.keys {
      do { _ = try validateGroup(id) }
      catch { errors[id] = error }
    }
    return errors
  }
}
