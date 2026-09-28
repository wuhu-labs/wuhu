#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Crypto

enum SignatureAlgorithm: Hashable, Sendable {
  case ed25519
  case p256
}

public enum VerifyingKey: Sendable {
  case ed25519(Curve25519.Signing.PublicKey)
  case p256(P256.Signing.PublicKey)

  // Labels are client-supplied data; anything but an exact tagged encoding
  // fails closed as no key. The tag is the only thing that ever selects a
  // verifier — callers must never pick a curve independently of the label.
  public init?(label: String) {
    if label.hasPrefix("ed25519:") {
      guard let raw = Data(base64Encoded: String(label.dropFirst("ed25519:".count))), raw.count == 32,
            let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
      else { return nil }
      self = .ed25519(key)
    } else if label.hasPrefix("p256:") {
      guard let raw = Data(base64Encoded: String(label.dropFirst("p256:".count))), raw.count == 65,
            let key = try? P256.Signing.PublicKey(x963Representation: raw)
      else { return nil }
      self = .p256(key)
    } else {
      return nil
    }
  }

  public var label: String {
    switch self {
    case let .ed25519(key): key.label
    case let .p256(key): key.label
    }
  }

  var algorithm: SignatureAlgorithm {
    switch self {
    case .ed25519: .ed25519
    case .p256: .p256
    }
  }

  public func isValidSignature(_ signature: Data, for message: Data) -> Bool {
    switch self {
    case let .ed25519(key):
      key.isValidSignature(signature, for: message)
    case let .p256(key):
      // Raw 64-byte r||s over SHA-256, the WebCrypto ECDSA shape; DER is rejected.
      (
        (try? P256.Signing.ECDSASignature(rawRepresentation: signature))
          .map { key.isValidSignature($0, for: message) }
      ) ?? false
    }
  }
}

extension Curve25519.Signing.PublicKey {
  public var label: String {
    "ed25519:" + self.rawRepresentation.base64EncodedString()
  }
}

extension Curve25519.Signing.PrivateKey {
  public var pubkeyLabel: String {
    self.publicKey.label
  }
}

extension P256.Signing.PublicKey {
  public var label: String {
    "p256:" + self.x963Representation.base64EncodedString()
  }
}

extension P256.Signing.PrivateKey {
  public var pubkeyLabel: String {
    self.publicKey.label
  }
}
