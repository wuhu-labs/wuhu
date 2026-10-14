#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Crypto
import struct SessionDomain.ModelSpecifier
import struct SessionDomain.SessionModelRoute

extension ProviderCatalog {
  public func validateGroup(_ id: String, effort: String? = nil) throws -> String {
    guard !id.isEmpty, let group = document.groups[id] else { throw CatalogError.unknownGroup(id) }
    guard document.providers[id] == nil, !group.members.isEmpty else {
      throw CatalogError.invalidGroup(group: id, reason: "group must have members and cannot also be a provider")
    }
    var ids: Set<String> = []
    var pairs: Set<ModelSpecifier> = []
    for member in group.members {
      do {
        guard !member.id.isEmpty, !member.provider.isEmpty, !member.model.isEmpty,
              ids.insert(member.id).inserted,
              pairs.insert(ModelSpecifier(provider: member.provider, model: member.model, effort: "")).inserted
        else {
          throw CatalogError.invalidGroup(group: id, reason: "empty or duplicate member id/provider/model pair")
        }
        _ = try validate(ModelSpecifier(provider: member.provider, model: member.model, effort: group.defaultEffort))
        if let effort { _ = try validate(ModelSpecifier(provider: member.provider, model: member.model, effort: effort)) }
      } catch let error as CatalogError {
        throw CatalogError.groupMember(group: id, member: member.id, reason: error)
      }
    }
    switch group.policy {
    case let .quotaAware(seconds):
      guard (0 ... 86400).contains(seconds) else { throw CatalogError.invalidGroup(group: id, reason: "holdDownSeconds must be 0...86400") }
    case let .select(member):
      guard ids.contains(member) else { throw CatalogError.invalidGroup(group: id, reason: "select member \(member) does not exist") }
    }
    return effort ?? group.defaultEffort
  }

  public func validateGroupReadiness(_ id: String, effort: String? = nil) async throws -> String {
    let effort = try validateGroup(id, effort: effort)
    for member in document.groups[id]!.members {
      do {
        let provider = document.providers[member.provider]!
        if provider.auth == .oidc {
          guard oidcToken != nil else { throw CatalogError.oidcNotConfigured(provider: member.provider) }
          do { try await oidcReadiness?(provider.baseURL) }
          catch { throw CatalogError.oidcNotConfigured(provider: member.provider) }
          continue
        }
        guard let credential = try await credentials.resolve(member.provider) else {
          throw CatalogError.missingCredential(provider: member.provider)
        }
        switch (provider.dialect, credential) {
        case let (.codex, .chatGPT(token, account)):
          guard !token.isEmpty, !account.isEmpty else { throw CatalogError.missingCredential(provider: member.provider) }
        case let (.responses, .apiKey(key)), let (.anthropic, .apiKey(key)), let (.claude, .apiKey(key)):
          guard !key.isEmpty else { throw CatalogError.missingCredential(provider: member.provider) }
        case (.claude, _): throw CatalogError.claudeAPIKeyRequired(provider: member.provider)
        default: throw CatalogError.credentialMismatch(provider: member.provider)
        }
      } catch let error as CatalogError {
        throw CatalogError.groupMember(group: id, member: member.id, reason: error)
      } catch {
        throw CatalogError.groupMember(group: id, member: member.id, reason: .invalidGroup(group: id, reason: "credential readiness failed"))
      }
    }
    return effort
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
    return route.specifier
  }
}

extension ModelsDocument.Provider {
  func validateCapacity(providerID: String) throws {
    for (window, size) in capacity ?? [:] {
      guard ["fiveHour", "sevenDay"].contains(window), size.isFinite, size > 0 else {
        throw CatalogError.invalidCapacity(provider: providerID, window: window)
      }
    }
  }

  public var routeFingerprint: String {
    let binding = [dialect.rawValue, baseURL.absoluteString, transport?.rawValue ?? "sse", auth?.rawValue ?? "credential", originator ?? "wuhu"].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    return SHA256.hash(data: Data(binding.utf8)).map { ("0" + String($0, radix: 16)).suffix(2) }.joined()
  }
}
