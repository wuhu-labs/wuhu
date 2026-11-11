public indirect enum CatalogError: Error, Hashable, Sendable, CustomStringConvertible {
  case invalidDocument
  case invalidProvider(provider: String, reason: String)
  case invalidGroupsDocument
  case unknownProvider(String)
  case unsupportedTarget(String)
  case unknownGroup(String)
  case noUsableMembers(String)
  case invalidCapacity(provider: String, window: String)
  case invalidGroup(group: String, reason: String)
  case groupMember(group: String, member: String, reason: CatalogError)
  case credentialLoginRequired(provider: String)
  case modelRouteInvalid(group: String, member: String)
  case invalidModel(provider: String, model: String)
  case oidcNotConfigured(provider: String)
  case unknownModel(provider: String, model: String)
  case unknownEffort(provider: String, model: String, effort: String)
  case missingCredential(provider: String)
  case credentialMismatch(provider: String)
  case invalidEndpoint(provider: String)
  case invalidTransport(provider: String)
  case invalidCacheWarming(String)
  case invalidOIDCDialect(provider: String)
  case invalidUsageSource(provider: String)
  case invalidFiveHourShare(provider: String)
  case invalidOpaqueReplay(provider: String, value: String)
  case sharedCredentialName(name: String, providers: [String])
  case unstorableCredentialName(provider: String, name: String)

  public var description: String {
    switch self {
    case .invalidGroupsDocument: "invalid /model-groups.json catalog shape"
    case let .invalidProvider(provider, reason): "invalid provider \(provider): \(reason)"
    case .invalidDocument: "invalid /models.json catalog shape"
    case let .unsupportedTarget(target): "unsupported model target: \(target); this operation requires a concrete provider/model"
    case let .noUsableMembers(group): "model group \(group) has no usable member"
    case let .invalidCapacity(provider, window): "invalid capacity for provider \(provider), window \(window): use a model's binding window name and a positive finite number"
    case let .unknownGroup(group): "unknown model group: \(group)"
    case let .invalidGroup(group, reason): "invalid model group \(group): \(reason)"
    case let .groupMember(group, member, reason): "model group \(group) member \(member): \(reason.description)"
    case let .credentialLoginRequired(provider): "credentialLoginRequired: \(provider) requires login after credential refresh refusal"
    case let .modelRouteInvalid(group, member): "modelRouteInvalid: model group \(group) pinned member \(member) was removed or rebound; restore it or Start over"
    case let .invalidModel(provider, model): "invalid context/output limits for \(provider)/\(model)"
    case let .oidcNotConfigured(provider): "OIDC authentication is not configured for provider \(provider)"
    case let .invalidCacheWarming(reason):
      "invalid cacheWarming configuration: \(reason)"
    case let .sharedCredentialName(name, providers):
      "providers \(providers.joined(separator: ", ")) all derive the credential name \(name); rename one"
    case let .unstorableCredentialName(provider, name):
      "provider \(provider) derives the credential name \(name), which starts with a digit or runs over 128 bytes; rename it"
    case let .invalidOpaqueReplay(provider, value):
      "invalid opaqueReplay \"\(value)\" for provider \(provider); expected affine or none"
    case let .invalidOIDCDialect(provider):
      "OIDC authentication is unsupported for Codex providers: \(provider)"
    case let .invalidEndpoint(provider): "provider endpoint must be an HTTP(S) URL without user information: \(provider)"
    case let .invalidTransport(provider):
      "websocket transport requires a Responses or Codex provider: \(provider)"
    case let .invalidUsageSource(provider):
      "usage \"gateway\" requires a Responses provider with a stored credential, not OIDC: \(provider)"
    case let .invalidFiveHourShare(provider):
      "invalid fiveHourShare for provider \(provider): use a fraction above 0 and at most 1"
    case let .unknownProvider(provider):
      "unknown provider: \(provider) (edit \(ModelsDocument.spacePath) or run `wuhu models update`)"
    case let .unknownModel(provider, model):
      "unknown model: \(provider)/\(model)"
    case let .unknownEffort(provider, model, effort):
      "unknown effort \"\(effort)\" for \(provider)/\(model)"
    case let .missingCredential(provider):
      "no credentials for provider \(provider) (run `wuhu auth set \(provider)` or `wuhu auth login \(provider)`)"
    case let .credentialMismatch(provider):
      "credentials for provider \(provider) are the wrong kind for its dialect (api key vs chatgpt login)"
    }
  }
}

extension CatalogError {
  public var code: String {
    switch self {
    case .credentialLoginRequired: "credentialLoginRequired"
    case .modelRouteInvalid: "modelRouteInvalid"
    case .noUsableMembers: "modelGroupUnavailable"
    case .unsupportedTarget: "unsupportedTarget"
    case .invalidDocument, .invalidGroupsDocument, .invalidProvider, .invalidGroup, .unknownGroup, .groupMember, .invalidCapacity, .invalidFiveHourShare: "modelGroupConfiguration"
    default: "invalidArgument"
    }
  }
}
