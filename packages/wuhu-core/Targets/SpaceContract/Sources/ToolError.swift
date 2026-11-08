import Contract
import JSONValue

@Contract
public enum ErrorCode: String, Codable, Equatable, Sendable {
  case aliasTaken
  case invalidAlias
  case memberRequired
  case notFound
  case conflict
  /// A copy's target is already there and the copy may not replace it.
  case exists
  /// A copy's source changed while it was being read.
  case sourceChanged
  case invalidPath
  case invalidArgument
  case unauthorized
  case forbidden
  case unsupported
  case unavailable
  /// A result larger than the call's byte allowance: a query result or a file read.
  case byteLimitExceeded
  case unknownKind
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
  /// Why a 401 refused a valid key's assertion: `assertionExpired` or
  /// `assertionNotYetValid`, both meaning the client re-signs by the server's
  /// `now` instead of signing out.
  public let reason: String?
}
