#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Dependencies
import Fetch

public enum ChatGPTAuthError: Error, CustomStringConvertible, Equatable, Sendable {
  case loginRequired(detail: String)
  case authorizationTimedOut
  case protocolFailure(String)
  case unreachable(hop: String, kind: TransportFailureKind)

  public var description: String {
    switch self {
    case let .loginRequired(detail):
      "ChatGPT credentials are no longer valid (\(detail)); run `wuhu auth login codex`"
    case .authorizationTimedOut:
      "device authorization timed out; run `wuhu auth login codex` again"
    case let .protocolFailure(detail):
      "ChatGPT auth request failed: \(detail)"
    case let .unreachable(hop, kind):
      "could not reach \(hop): \(kind.rawValue)"
    }
  }
}

public enum ChatGPTAuth {
  public static let clientID: String = "app_EMoamEEZ73f0CkXaXp7hrann"

  static let base = URL(string: "https://auth.openai.com")!
  static var tokenURL: URL { base.appendingPathComponent("oauth/token") }
  static var revokeURL: URL { base.appendingPathComponent("oauth/revoke") }
  static var deviceUserCodeURL: URL { base.appendingPathComponent("api/accounts/deviceauth/usercode") }
  static var deviceTokenURL: URL { base.appendingPathComponent("api/accounts/deviceauth/token") }
  static var deviceRedirectURI: String { base.appendingPathComponent("deviceauth/callback").absoluteString }
  public static let deviceVerificationURL: URL = URL(string: "https://auth.openai.com/codex/device")!
  static let deviceAuthorizationTimeout: Duration = .seconds(15 * 60)

  public struct DeviceAuthorization: Sendable, Hashable {
    public var deviceAuthID: String
    public var userCode: String
    public var interval: Duration
  }

  // A transport failure here is indistinguishable from a model-call failure once
  // it reaches the session loop, so every hop states which one it was.
  static func send(_ request: Request, hop: String) async throws -> Response {
    @Dependency(\.fetch) var fetch
    do {
      return try await fetch(request)
    } catch let error as FetchError {
      guard case let .transportFailure(kind) = error else { throw error }
      throw ChatGPTAuthError.unreachable(hop: hop, kind: kind)
    }
  }

  public static func startDeviceAuthorization() async throws -> DeviceAuthorization {
    let response = try await send(
      Request(
        url: deviceUserCodeURL,
        method: .post,
        body: try .json(DeviceUserCodeRequest(clientID: clientID)),
      ),
      hop: "auth.openai.com to start ChatGPT device authorization",
    )
    guard response.status == .ok else {
      let body = (try? await response.body.text()) ?? ""
      throw ChatGPTAuthError.protocolFailure("device code request returned \(response.status.code): \(body.prefix(300))")
    }
    let payload = try await response.body.json(DeviceUserCodeResponse.self)
    return DeviceAuthorization(
      deviceAuthID: payload.deviceAuthID,
      userCode: payload.userCode,
      interval: .seconds(max(1, payload.interval ?? 5)),
    )
  }

  public static func awaitDeviceGrant(_ authorization: DeviceAuthorization) async throws -> ChatGPTTokens {
    @Dependency(\.continuousClock) var clock
    var interval = authorization.interval
    var elapsed: Duration = .zero
    while elapsed < deviceAuthorizationTimeout {
      let response = try await send(
        Request(
          url: deviceTokenURL,
          method: .post,
          body: try .json(DeviceTokenRequest(
            deviceAuthID: authorization.deviceAuthID,
            userCode: authorization.userCode,
          )),
        ),
        hop: "auth.openai.com to poll ChatGPT device authorization",
      )
      if response.status == .ok {
        let grant = try await response.body.json(DeviceTokenResponse.self)
        return try await exchangeAuthorizationCode(grant.authorizationCode, verifier: grant.codeVerifier)
      }
      let body = (try? await response.body.text()) ?? ""
      switch deviceGrantState(status: response.status, body: body) {
      case .pending:
        break
      case .slowDown:
        interval += .seconds(5)
      case .failed:
        throw ChatGPTAuthError.protocolFailure("device authorization returned \(response.status.code): \(body.prefix(300))")
      }
      try await clock.sleep(for: interval)
      elapsed += interval
    }
    throw ChatGPTAuthError.authorizationTimedOut
  }

  enum DeviceGrantState: Equatable {
    case pending
    case slowDown
    case failed
  }

  static func deviceGrantState(status: Status, body: String) -> DeviceGrantState {
    if status.code == 403 || status.code == 404 { return .pending }
    if body.contains("deviceauth_authorization_pending") { return .pending }
    if body.contains("slow_down") { return .slowDown }
    return .failed
  }

  static func exchangeAuthorizationCode(_ code: String, verifier: String) async throws -> ChatGPTTokens {
    let response = try await send(
      Request(
        url: tokenURL,
        method: .post,
        body: formBody([
          ("grant_type", "authorization_code"),
          ("client_id", clientID),
          ("code", code),
          ("code_verifier", verifier),
          ("redirect_uri", deviceRedirectURI),
        ]),
      ),
      hop: "auth.openai.com to exchange the ChatGPT authorization code",
    )
    guard response.status == .ok else {
      let body = (try? await response.body.text()) ?? ""
      throw ChatGPTAuthError.protocolFailure("token exchange returned \(response.status.code): \(body.prefix(300))")
    }
    let payload = try await response.body.json(TokenResponse.self)
    return try tokens(from: payload, previous: nil)
  }

  public static func refresh(_ tokens: ChatGPTTokens) async throws -> ChatGPTTokens {
    let response = try await send(
      Request(
        url: tokenURL,
        method: .post,
        body: try .json(RefreshRequest(clientID: clientID, refreshToken: tokens.refreshToken)),
      ),
      hop: "auth.openai.com to refresh ChatGPT credentials",
    )
    guard response.status == .ok else {
      let body = (try? await response.body.text()) ?? ""
      if isPermanentRefreshFailure(status: response.status, body: body) {
        throw ChatGPTAuthError.loginRequired(detail: "refresh returned \(response.status.code)")
      }
      throw ChatGPTAuthError.protocolFailure("token refresh returned \(response.status.code): \(body.prefix(300))")
    }
    let payload = try await response.body.json(TokenResponse.self)
    return try Self.tokens(from: payload, previous: tokens)
  }

  static func isPermanentRefreshFailure(status: Status, body: String) -> Bool {
    if status == .unauthorized { return true }
    return ["refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"]
      .contains(where: body.contains)
  }

  public static func revoke(_ tokens: ChatGPTTokens) async throws {
    let response = try await send(
      Request(
        url: revokeURL,
        method: .post,
        body: formBody([
          ("client_id", clientID),
          ("token", tokens.refreshToken),
          ("token_type_hint", "refresh_token"),
        ]),
      ),
      hop: "auth.openai.com to revoke ChatGPT credentials",
    )
    guard response.status.kind == .successful else {
      let body = (try? await response.body.text()) ?? ""
      throw ChatGPTAuthError.protocolFailure("revoke returned \(response.status.code): \(body.prefix(300))")
    }
  }

  static func tokens(from response: TokenResponse, previous: ChatGPTTokens?) throws -> ChatGPTTokens {
    @Dependency(\.date.now) var now
    guard let accessToken = response.accessToken ?? previous?.accessToken else {
      throw ChatGPTAuthError.protocolFailure("token response carries no access_token")
    }
    guard let refreshToken = response.refreshToken ?? previous?.refreshToken else {
      throw ChatGPTAuthError.protocolFailure("token response carries no refresh_token")
    }
    guard let accountID = accountID(fromAccessToken: accessToken) ?? previous?.accountID else {
      throw ChatGPTAuthError.protocolFailure("access token carries no chatgpt_account_id claim")
    }
    let expiresAt: Date
    if let expiresIn = response.expiresIn {
      expiresAt = now.addingTimeInterval(TimeInterval(expiresIn))
    } else if let exp = jwtClaims(accessToken)?.exp {
      expiresAt = Date(timeIntervalSince1970: exp)
    } else {
      expiresAt = now.addingTimeInterval(3600)
    }
    return ChatGPTTokens(
      idToken: response.idToken ?? previous?.idToken,
      accessToken: accessToken,
      refreshToken: refreshToken,
      accountID: accountID,
      expiresAt: expiresAt,
    )
  }

  public static func accountID(fromAccessToken token: String) -> String? {
    jwtClaims(token)?.auth?.chatgptAccountID
  }

  static func jwtClaims(_ jwt: String) -> JWTClaims? {
    let parts = jwt.split(separator: ".")
    guard parts.count == 3, let payload = base64URLDecode(String(parts[1])) else { return nil }
    return try? JSONDecoder().decode(JWTClaims.self, from: payload)
  }

  static func base64URLDecode(_ value: String) -> Data? {
    var base64 = value
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 {
      base64 += "="
    }
    return Data(base64Encoded: base64)
  }

  static func formBody(_ fields: [(String, String)]) -> Body {
    let encoded = fields.map { name, value in
      "\(name)=\(formEscape(value))"
    }.joined(separator: "&")
    return .bytes(Data(encoded.utf8), contentType: "application/x-www-form-urlencoded")
  }

  static func formEscape(_ value: String) -> String {
    var escaped = ""
    for byte in value.utf8 {
      switch byte {
      case UInt8(ascii: "a") ... UInt8(ascii: "z"),
           UInt8(ascii: "A") ... UInt8(ascii: "Z"),
           UInt8(ascii: "0") ... UInt8(ascii: "9"),
           UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
        escaped.unicodeScalars.append(Unicode.Scalar(byte))
      default:
        let hex = "0123456789ABCDEF"
        escaped += "%"
        escaped.append(hex[hex.index(hex.startIndex, offsetBy: Int(byte >> 4))])
        escaped.append(hex[hex.index(hex.startIndex, offsetBy: Int(byte & 0x0F))])
      }
    }
    return escaped
  }
}

struct JWTClaims: Decodable {
  var exp: Double?
  var auth: Auth?

  enum CodingKeys: String, CodingKey {
    case exp
    case auth = "https://api.openai.com/auth"
  }

  struct Auth: Decodable {
    var chatgptAccountID: String?

    enum CodingKeys: String, CodingKey {
      case chatgptAccountID = "chatgpt_account_id"
    }
  }
}

private struct DeviceUserCodeRequest: Encodable {
  var clientID: String

  enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
  }
}

private struct DeviceUserCodeResponse: Decodable {
  var deviceAuthID: String
  var userCode: String
  var interval: Int?

  enum CodingKeys: String, CodingKey {
    case deviceAuthID = "device_auth_id"
    case userCode = "user_code"
    case interval
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceAuthID = try container.decode(String.self, forKey: .deviceAuthID)
    userCode = try container.decode(String.self, forKey: .userCode)
    // The server has been observed sending interval as both a number and a
    // numeric string.
    if let number = try? container.decodeIfPresent(Int.self, forKey: .interval) {
      interval = number
    } else if let text = try? container.decodeIfPresent(String.self, forKey: .interval) {
      interval = Int(text.filter { !$0.isWhitespace })
    } else {
      interval = nil
    }
  }
}

private struct DeviceTokenRequest: Encodable {
  var deviceAuthID: String
  var userCode: String

  enum CodingKeys: String, CodingKey {
    case deviceAuthID = "device_auth_id"
    case userCode = "user_code"
  }
}

private struct DeviceTokenResponse: Decodable {
  var authorizationCode: String
  var codeVerifier: String

  enum CodingKeys: String, CodingKey {
    case authorizationCode = "authorization_code"
    case codeVerifier = "code_verifier"
  }
}

private struct RefreshRequest: Encodable {
  var clientID: String
  var grantType: String = "refresh_token"
  var refreshToken: String

  enum CodingKeys: String, CodingKey {
    case clientID = "client_id"
    case grantType = "grant_type"
    case refreshToken = "refresh_token"
  }
}

struct TokenResponse: Decodable {
  var idToken: String?
  var accessToken: String?
  var refreshToken: String?
  var expiresIn: Int?

  enum CodingKeys: String, CodingKey {
    case idToken = "id_token"
    case accessToken = "access_token"
    case refreshToken = "refresh_token"
    case expiresIn = "expires_in"
  }
}
