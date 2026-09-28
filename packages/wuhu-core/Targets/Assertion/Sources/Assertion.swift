#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Crypto
import JSONValue

public struct AssertionClaims: Hashable, Sendable {
  public var key: String
  public var space: String
  public var expiresAt: Date

  public init(key: String, space: String, expiresAt: Date) {
    self.key = key
    self.space = space
    self.expiresAt = expiresAt
  }

  public func isLive(at now: Date) -> Bool {
    now < self.expiresAt
  }

  public func signed(by key: Curve25519.Signing.PrivateKey) throws -> SignedAssertion {
    try self.signed(header: eddsaHeader) { try key.signature(for: $0) }
  }

  public func signed(by key: P256.Signing.PrivateKey) throws -> SignedAssertion {
    try self.signed(header: es256Header) { try key.signature(for: $0).rawRepresentation }
  }

  private func signed(header: String, sign: (Data) throws -> Data) throws -> SignedAssertion {
    let exp = Int(self.expiresAt.timeIntervalSince1970)
    let payload: JSONValue = ["key": .string(self.key), "space": .string(self.space), "exp": .integer(exp)]
    let signingInput = header + "." + base64URL(Data(payload.jsonString().utf8))
    let signature = try sign(Data(signingInput.utf8))
    guard let assertion = SignedAssertion(rawValue: signingInput + "." + base64URL(signature)) else {
      preconditionFailure("a freshly minted assertion must parse")
    }
    return assertion
  }
}

public struct SignedAssertion: Hashable, Sendable {
  public let claims: AssertionClaims
  public let rawValue: String
  private let algorithm: SignatureAlgorithm
  private let signingInput: Data
  private let signature: Data

  public init?(rawValue: String) {
    let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3, let algorithm = headerAlgorithms[String(parts[0])],
          let payloadData = base64URLDecoded(parts[1]),
          let signature = base64URLDecoded(parts[2]),
          let payload = JSONValue.parse(String(decoding: payloadData, as: UTF8.self)),
          let wire = try? JSONValueDecoder().decode(WireClaims.self, from: payload),
          // A session claim scoped an assertion to one contractor session; a
          // server without contractors refuses one rather than widen it.
          payload.object?["session"] == nil
    else { return nil }
    self.claims = AssertionClaims(
      key: wire.key,
      space: wire.space,
      expiresAt: Date(timeIntervalSince1970: TimeInterval(wire.exp)),
    )
    self.rawValue = rawValue
    self.algorithm = algorithm
    self.signingInput = Data((parts[0] + "." + parts[1]).utf8)
    self.signature = signature
  }

  // An enrolled pubkey is client-supplied data and may not parse as a key;
  // fail closed as unauthenticated, never trap. The header's declared alg
  // must equal the key's algorithm: a signature must never verify under a
  // curve other than the one the key row names (algorithm confusion).
  public func hasValidSignature(publicKeyLabel: String) -> Bool {
    guard let key = VerifyingKey(label: publicKeyLabel), key.algorithm == self.algorithm else { return false }
    return key.isValidSignature(self.signature, for: self.signingInput)
  }
}

private struct WireClaims: Decodable {
  var key: String
  var space: String
  var exp: Int
}

private let eddsaHeader = base64URL(Data(#"{"alg":"EdDSA","typ":"JWT"}"#.utf8))
private let es256Header = base64URL(Data(#"{"alg":"ES256","typ":"JWT"}"#.utf8))
private let headerAlgorithms: [String: SignatureAlgorithm] = [
  eddsaHeader: .ed25519,
  es256Header: .p256,
]

private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private func base64URLDecoded(_ text: Substring) -> Data? {
  var standard = text
    .replacingOccurrences(of: "-", with: "+")
    .replacingOccurrences(of: "_", with: "/")
  while standard.count % 4 != 0 {
    standard += "="
  }
  return Data(base64Encoded: standard)
}
