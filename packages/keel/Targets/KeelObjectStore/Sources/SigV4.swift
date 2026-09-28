#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Crypto

public struct SigV4Credentials: Hashable, Sendable {
  public var accessKeyID: String
  public var secretAccessKey: String
  public var sessionToken: String?

  public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
    self.accessKeyID = accessKeyID
    self.secretAccessKey = secretAccessKey
    self.sessionToken = sessionToken
  }
}

enum SigV4 {
  static let algorithm = "AWS4-HMAC-SHA256"
  static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  static let unsignedPayload = "UNSIGNED-PAYLOAD"

  struct Header: Sendable {
    var name: String
    var value: String
  }

  static func canonicalURI(path: String, doubleEncode: Bool) -> String {
    let once = uriEncode(path, encodeSlash: false)
    return doubleEncode ? uriEncode(once, encodeSlash: false) : once
  }

  static func canonicalQuery(_ items: [(name: String, value: String)]) -> String {
    items
      .map { (uriEncode($0.name, encodeSlash: true), uriEncode($0.value, encodeSlash: true)) }
      .sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
      .map { "\($0.0)=\($0.1)" }
      .joined(separator: "&")
  }

  static func canonicalHeaders(_ headers: [Header]) -> (canonical: String, signed: String) {
    let normalized = headers
      .map { (name: $0.name.lowercased(), value: trimAll($0.value)) }
      .sorted { $0.name < $1.name }
    let canonical = normalized.map { "\($0.name):\($0.value)\n" }.joined()
    let signed = normalized.map(\.name).joined(separator: ";")
    return (canonical, signed)
  }

  static func canonicalRequest(
    method: String,
    canonicalURI: String,
    canonicalQuery: String,
    headers: [Header],
    payloadHash: String,
  ) -> (request: String, signedHeaders: String) {
    let (canonicalHeaders, signedHeaders) = self.canonicalHeaders(headers)
    let request = [
      method,
      canonicalURI,
      canonicalQuery,
      canonicalHeaders + "\n" + signedHeaders,
      payloadHash,
    ].joined(separator: "\n")
    return (request, signedHeaders)
  }

  static func stringToSign(amzDate: String, scope: String, canonicalRequest: String) -> String {
    [
      self.algorithm,
      amzDate,
      scope,
      hexSHA256(Array(canonicalRequest.utf8)),
    ].joined(separator: "\n")
  }

  static func scope(dateStamp: String, region: String, service: String) -> String {
    "\(dateStamp)/\(region)/\(service)/aws4_request"
  }

  static func signingKey(
    secretAccessKey: String,
    dateStamp: String,
    region: String,
    service: String,
  ) -> [UInt8] {
    let kSecret = Array("AWS4\(secretAccessKey)".utf8)
    let kDate = hmac(key: kSecret, message: dateStamp)
    let kRegion = hmac(key: kDate, message: region)
    let kService = hmac(key: kRegion, message: service)
    return hmac(key: kService, message: "aws4_request")
  }

  static func signature(signingKey: [UInt8], stringToSign: String) -> String {
    hexEncode(hmac(key: signingKey, message: stringToSign))
  }

  static func authorizationHeader(
    accessKeyID: String,
    scope: String,
    signedHeaders: String,
    signature: String,
  ) -> String {
    "\(self.algorithm) Credential=\(accessKeyID)/\(scope), "
      + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
  }
}

extension SigV4 {
  // AWS uRIEncode: unreserved characters pass through, everything else is
  // percent-encoded with uppercase hex; `/` is conditionally preserved (path
  // segments keep it, query names/values do not).
  static func uriEncode(_ string: String, encodeSlash: Bool) -> String {
    var out = ""
    out.reserveCapacity(string.utf8.count)
    for byte in string.utf8 {
      switch byte {
      case 0x41 ... 0x5A, 0x61 ... 0x7A, 0x30 ... 0x39,
           0x2D, 0x2E, 0x5F, 0x7E:
        out.unicodeScalars.append(UnicodeScalar(byte))
      case 0x2F where !encodeSlash:
        out.append("/")
      default:
        out.append(percentEncoded(byte))
      }
    }
    return out
  }

  static func trimAll(_ value: String) -> String {
    let trimmed = value.drop { $0 == " " }.reversed().drop { $0 == " " }.reversed()
    var out = ""
    var previousWasSpace = false
    for character in trimmed {
      if character == " " {
        if !previousWasSpace { out.append(" ") }
        previousWasSpace = true
      } else {
        out.append(character)
        previousWasSpace = false
      }
    }
    return out
  }
}

private let lowerHex = Array("0123456789abcdef".utf8)
private let upperHex = Array("0123456789ABCDEF".utf8)

private func percentEncoded(_ byte: UInt8) -> String {
  var out = "%"
  out.unicodeScalars.append(UnicodeScalar(upperHex[Int(byte >> 4)]))
  out.unicodeScalars.append(UnicodeScalar(upperHex[Int(byte & 0x0F)]))
  return out
}

func hexEncode(_ bytes: some Sequence<UInt8>) -> String {
  var out = ""
  for byte in bytes {
    out.unicodeScalars.append(UnicodeScalar(lowerHex[Int(byte >> 4)]))
    out.unicodeScalars.append(UnicodeScalar(lowerHex[Int(byte & 0x0F)]))
  }
  return out
}

func hexSHA256(_ bytes: [UInt8]) -> String {
  hexEncode(SHA256.hash(data: bytes))
}

private func hmac(key: [UInt8], message: String) -> [UInt8] {
  Array(HMAC<SHA256>.authenticationCode(for: Array(message.utf8), using: SymmetricKey(data: key)))
}
