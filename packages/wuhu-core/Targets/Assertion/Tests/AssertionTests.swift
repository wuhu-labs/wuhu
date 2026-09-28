#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Assertion
import Crypto
import Testing

@Suite struct AssertionTests {
  let key = Curve25519.Signing.PrivateKey()
  let now = Date(timeIntervalSince1970: 1_750_000_000)

  var claims: AssertionClaims {
    AssertionClaims(
      key: key.pubkeyLabel,
      space: "sha256:" + String(repeating: "a", count: 64),
      expiresAt: now.addingTimeInterval(3600),
    )
  }

  @Test func mintedAssertionRoundTripsAndVerifies() throws {
    let minted = try claims.signed(by: key)
    let parsed = try #require(SignedAssertion(rawValue: minted.rawValue))
    #expect(parsed.claims == claims)
    #expect(parsed == minted)
    #expect(parsed.hasValidSignature(publicKeyLabel: key.pubkeyLabel))
    #expect(!parsed.hasValidSignature(publicKeyLabel: Curve25519.Signing.PrivateKey().pubkeyLabel))
  }

  @Test func thePayloadCarriesKeySpaceAndExpOnly() throws {
    let minted = try claims.signed(by: key)
    let encoded = try #require(minted.rawValue.split(separator: ".").dropFirst().first)
    var standard = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while standard.count % 4 != 0 { standard += "=" }
    let data = try #require(Data(base64Encoded: standard))
    let exp = Int(claims.expiresAt.timeIntervalSince1970)
    #expect(
      String(decoding: data, as: UTF8.self)
        == #"{"key":"\#(key.pubkeyLabel)","space":"\#(claims.space)","exp":\#(exp)}"#,
    )
  }

  // Only contractor daemons minted session claims; one is refused outright
  // rather than read as an unscoped credential.
  @Test func aSessionClaimNoLongerParses() throws {
    let header = try #require(claims.signed(by: key).rawValue.split(separator: ".").first)
    let exp = Int(claims.expiresAt.timeIntervalSince1970)
    let payload = #"{"key":"k","space":"s","exp":\#(exp),"session":"sess-1"}"#
    let body = Data(payload.utf8).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
    #expect(SignedAssertion(rawValue: "\(header).\(body).AAAA") == nil)
  }

  @Test func expIsWholeSecondsOnTheWire() throws {
    var sub = claims
    sub.expiresAt = now.addingTimeInterval(3600.75)
    let minted = try sub.signed(by: key)
    #expect(minted.claims.expiresAt == now.addingTimeInterval(3600))
  }

  @Test func aTamperedPayloadFailsVerification() throws {
    var forgedClaims = claims
    forgedClaims.space = "sha256:" + String(repeating: "b", count: 64)
    let parts = try claims.signed(by: key).rawValue.split(separator: ".").map(String.init)
    let forgedParts = try forgedClaims.signed(by: key).rawValue.split(separator: ".").map(String.init)
    let spliced = try #require(SignedAssertion(rawValue: [parts[0], forgedParts[1], parts[2]].joined(separator: ".")))
    #expect(spliced.claims.space == forgedClaims.space)
    #expect(!spliced.hasValidSignature(publicKeyLabel: key.pubkeyLabel))
  }

  @Test func malformedAssertionsDoNotParse() throws {
    let minted = try claims.signed(by: key).rawValue
    let parts = minted.split(separator: ".").map(String.init)
    #expect(SignedAssertion(rawValue: "") == nil)
    #expect(SignedAssertion(rawValue: "a.b") == nil)
    #expect(SignedAssertion(rawValue: minted + ".d") == nil)
    #expect(SignedAssertion(rawValue: ["bm90LWEtaGVhZGVy", parts[1], parts[2]].joined(separator: ".")) == nil)
    #expect(SignedAssertion(rawValue: [parts[0], "!!!", parts[2]].joined(separator: ".")) == nil)
    let truncated = base64URLObject(#"{"key":"k","space":"s"}"#)
    #expect(SignedAssertion(rawValue: [parts[0], truncated, parts[2]].joined(separator: ".")) == nil)
    let wrongType = base64URLObject(#"{"key":"k","space":"s","exp":"soon"}"#)
    #expect(SignedAssertion(rawValue: [parts[0], wrongType, parts[2]].joined(separator: ".")) == nil)
  }

  @Test func expiryIsExclusiveOfTheBoundary() {
    #expect(!claims.isLive(at: claims.expiresAt))
    #expect(claims.isLive(at: claims.expiresAt.addingTimeInterval(-1)))
    #expect(!claims.isLive(at: claims.expiresAt.addingTimeInterval(1)))
  }

  @Test func junkPublicKeyLabelsFailClosed() throws {
    let minted = try claims.signed(by: key)
    #expect(!minted.hasValidSignature(publicKeyLabel: "ed25519:phone"))
    #expect(!minted.hasValidSignature(publicKeyLabel: ""))
    #expect(!minted.hasValidSignature(publicKeyLabel: "ssh-ed25519 AAAA"))
  }

  @Test func publicKeyLabelsRoundTrip() throws {
    for label in [key.pubkeyLabel, P256.Signing.PrivateKey().pubkeyLabel] {
      let parsed = try #require(VerifyingKey(label: label))
      #expect(parsed.label == label)
      #expect(VerifyingKey(label: String(label.dropFirst(1))) == nil)
    }
    #expect(VerifyingKey(label: "ed25519:AAA") == nil)
    #expect(VerifyingKey(label: "rsa:AAAA") == nil)
    #expect(VerifyingKey(label: "") == nil)
  }

  @Test func p256MintedAssertionRoundTripsAndVerifies() throws {
    let p256 = P256.Signing.PrivateKey()
    var claims = self.claims
    claims.key = p256.pubkeyLabel
    let minted = try claims.signed(by: p256)
    let parsed = try #require(SignedAssertion(rawValue: minted.rawValue))
    #expect(parsed.claims == claims)
    #expect(parsed == minted)
    #expect(parsed.hasValidSignature(publicKeyLabel: p256.pubkeyLabel))
    #expect(!parsed.hasValidSignature(publicKeyLabel: P256.Signing.PrivateKey().pubkeyLabel))
  }

  @Test func anAssertionOnlyVerifiesAgainstAKeyOfItsOwnAlgorithm() throws {
    let p256 = P256.Signing.PrivateKey()
    let eddsaMinted = try claims.signed(by: key)
    var p256Claims = claims
    p256Claims.key = p256.pubkeyLabel
    let es256Minted = try p256Claims.signed(by: p256)
    #expect(!eddsaMinted.hasValidSignature(publicKeyLabel: p256.pubkeyLabel))
    #expect(!es256Minted.hasValidSignature(publicKeyLabel: key.pubkeyLabel))
  }

  @Test func aHeaderKeyAlgorithmMismatchFailsEvenWithAValidRawSignature() throws {
    let payload = base64URLObject(#"{"key":"k","space":"s","exp":1750003600}"#)

    let es256Input = base64URLObject(#"{"alg":"ES256","typ":"JWT"}"#) + "." + payload
    let ed25519Signed = es256Input + "." + base64URLData(try key.signature(for: Data(es256Input.utf8)))
    let confusedEd = try #require(SignedAssertion(rawValue: ed25519Signed))
    #expect(!confusedEd.hasValidSignature(publicKeyLabel: key.pubkeyLabel))

    let p256 = P256.Signing.PrivateKey()
    let eddsaInput = base64URLObject(#"{"alg":"EdDSA","typ":"JWT"}"#) + "." + payload
    let p256Signed = eddsaInput + "." + base64URLData(try p256.signature(for: Data(eddsaInput.utf8)).rawRepresentation)
    let confusedP256 = try #require(SignedAssertion(rawValue: p256Signed))
    #expect(!confusedP256.hasValidSignature(publicKeyLabel: p256.pubkeyLabel))
  }

  @Test func unknownHeaderAlgorithmsDoNotParse() throws {
    let payload = base64URLObject(#"{"key":"k","space":"s","exp":1}"#)
    for header in [#"{"alg":"none","typ":"JWT"}"#, #"{"alg":"HS256","typ":"JWT"}"#, #"{"alg":"ES256","typ":"JWS"}"#] {
      #expect(SignedAssertion(rawValue: base64URLObject(header) + "." + payload + ".AAAA") == nil)
    }
  }

  @Test func aSignatureUnderOneCurveDoesNotVerifyUnderTheOther() throws {
    let message = Data("wuhu-share-login:slc_x".utf8)
    let p256 = P256.Signing.PrivateKey()
    let edKey = try #require(VerifyingKey(label: key.pubkeyLabel))
    let pKey = try #require(VerifyingKey(label: p256.pubkeyLabel))
    let edSignature = try key.signature(for: message)
    let p256Signature = try p256.signature(for: message)
    #expect(edKey.isValidSignature(edSignature, for: message))
    #expect(pKey.isValidSignature(p256Signature.rawRepresentation, for: message))
    #expect(!edKey.isValidSignature(p256Signature.rawRepresentation, for: message))
    #expect(!pKey.isValidSignature(edSignature, for: message))
    #expect(!pKey.isValidSignature(p256Signature.derRepresentation, for: message))
    #expect(!pKey.isValidSignature(Data(), for: message))
    #expect(!pKey.isValidSignature(Data(repeating: 1, count: 65), for: message))
  }

  @Test func junkP256LabelsFailClosed() throws {
    let p256 = P256.Signing.PrivateKey()
    var claims = self.claims
    claims.key = p256.pubkeyLabel
    let minted = try claims.signed(by: p256)
    #expect(!minted.hasValidSignature(publicKeyLabel: "p256:phone"))
    #expect(!minted.hasValidSignature(publicKeyLabel: "p256:"))
    for count in [0, 33, 64, 66, 1024] {
      #expect(VerifyingKey(label: "p256:" + Data(repeating: 4, count: count).base64EncodedString()) == nil)
    }
    #expect(VerifyingKey(label: "p256:" + Data(repeating: 0xFF, count: 65).base64EncodedString()) == nil)
    #expect(VerifyingKey(label: "p256:" + p256.publicKey.compressedRepresentation.base64EncodedString()) == nil)
    #expect(VerifyingKey(label: "p256:" + p256.publicKey.rawRepresentation.base64EncodedString()) == nil)
  }
}

private func base64URLObject(_ json: String) -> String {
  base64URLData(Data(json.utf8))
}

private func base64URLData(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}
