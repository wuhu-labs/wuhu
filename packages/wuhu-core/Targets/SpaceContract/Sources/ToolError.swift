import Contract
import JSONValue

@Contract
public enum ErrorCode: String, Codable, Equatable, Sendable {
  case notFound
  case conflict
  case invalidPath
  case invalidArgument
  case unauthorized
  case unsupported
  case unavailable
  case `internal`
  case providerNotConfigured = "provider_not_configured"
  case providerAuth = "provider_auth"
  case providerRegion = "provider_region"
  case providerEntitlement = "provider_entitlement"
  case providerRateLimited = "provider_rate_limited"
  case unsupportedFeature = "unsupported_feature"
  case capabilityInvalidArgument = "invalid_argument"
  case providerUnavailable = "provider_unavailable"
}

@Contract
public struct ToolError: Codable, Equatable, Sendable {
  public let code: ErrorCode
  public let message: String
  public let hint: String?
  /// A conflict's current version token, when the verb reports one.
  public let token: String?
}
