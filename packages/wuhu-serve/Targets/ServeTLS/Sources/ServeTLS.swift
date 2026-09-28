#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

#if canImport(Glibc)
  import Glibc
#elseif canImport(Darwin)
  import Darwin
#endif

import Crypto
import enum PinnedTLS.PinnedTLS
import enum PinnedTLS.PinnedTLSError
import SwiftASN1
import X509

public struct TLSIdentity: Sendable {
  public var certificatePEM: String
  public var privateKeyPEM: String

  public init(certificatePEM: String, privateKeyPEM: String) {
    self.certificatePEM = certificatePEM
    self.privateKeyPEM = privateKeyPEM
  }

  public func fingerprint() throws -> String {
    try TLSIdentity.fingerprint(certificatePEM: self.certificatePEM)
  }

  // The identity's PEM may carry a chain; the fingerprint names the leaf.
  public static func fingerprint(certificatePEM: String) throws -> String {
    guard let leaf = try PEMDocument.parseMultiple(pemString: certificatePEM).first,
          leaf.discriminator == "CERTIFICATE"
    else {
      throw PinnedTLSError.invalidPinnedCertificate
    }
    return self.fingerprint(certificateDER: leaf.derBytes)
  }

  public static func fingerprint(certificateDER: some Sequence<UInt8>) -> String {
    PinnedTLS.fingerprint(certificateDER: certificateDER)
  }
}

extension TLSIdentity {
  public static func selfSigned(
    hosts: [String],
    privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
    now: Date = Date(),
    validity: TimeInterval = 365 * 24 * 3600,
  ) throws -> TLSIdentity {
    let key = Certificate.PrivateKey(privateKey)
    let name = try DistinguishedName {
      CommonName(hosts.first ?? "localhost")
    }
    // The self-signed cert must be its own trust anchor: BoringSSL refuses a
    // non-CA leaf as a pinned trust root (no partial-chain evaluation).
    let extensions = try Certificate.Extensions {
      Critical(BasicConstraints.isCertificateAuthority(maxPathLength: nil))
      Critical(try KeyUsage(digitalSignature: true, keyCertSign: true))
      try ExtendedKeyUsage([.serverAuth])
      SubjectAlternativeNames(hosts.map(generalName(host:)))
    }
    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(),
      publicKey: key.publicKey,
      notValidBefore: now.addingTimeInterval(-3600),
      notValidAfter: now.addingTimeInterval(validity),
      issuer: name,
      subject: name,
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: extensions,
      issuerPrivateKey: key,
    )
    return TLSIdentity(
      certificatePEM: try certificate.serializeAsPEM().pemString,
      privateKeyPEM: privateKey.pemRepresentation,
    )
  }

  public static func issued(
    hosts: [String],
    by issuer: TLSIdentity,
    privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey(),
    now: Date = Date(),
    validity: TimeInterval = 365 * 24 * 3600,
  ) throws -> TLSIdentity {
    let issuerCertificate = try Certificate(pemEncoded: issuer.certificatePEM)
    let issuerKey = Certificate.PrivateKey(try P256.Signing.PrivateKey(pemRepresentation: issuer.privateKeyPEM))
    let key = Certificate.PrivateKey(privateKey)
    let extensions = try Certificate.Extensions {
      Critical(BasicConstraints.notCertificateAuthority)
      Critical(try KeyUsage(digitalSignature: true))
      try ExtendedKeyUsage([.serverAuth])
      SubjectAlternativeNames(hosts.map(generalName(host:)))
    }
    let certificate = try Certificate(
      version: .v3,
      serialNumber: Certificate.SerialNumber(),
      publicKey: key.publicKey,
      notValidBefore: now.addingTimeInterval(-3600),
      notValidAfter: now.addingTimeInterval(validity),
      issuer: issuerCertificate.subject,
      subject: try DistinguishedName {
        CommonName(hosts.first ?? "localhost")
      },
      signatureAlgorithm: .ecdsaWithSHA256,
      extensions: extensions,
      issuerPrivateKey: issuerKey,
    )
    return TLSIdentity(
      certificatePEM: try certificate.serializeAsPEM().pemString + "\n" + issuer.certificatePEM,
      privateKeyPEM: privateKey.pemRepresentation,
    )
  }

  public static func loadOrCreate(directory: URL, hosts: [String], now: Date = Date()) async throws -> TLSIdentity {
    let certificateURL = directory.appendingPathComponent("cert.pem")
    let privateKeyURL = directory.appendingPathComponent("key.pem")
    if let identity = try loadUsable(certificateURL: certificateURL, privateKeyURL: privateKeyURL, now: now) {
      return identity
    }
    let identity = try selfSigned(hosts: hosts, now: now)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(identity.certificatePEM.utf8).write(to: certificateURL)
    try Data(identity.privateKeyPEM.utf8).write(to: privateKeyURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
    return identity
  }

  private static func loadUsable(certificateURL: URL, privateKeyURL: URL, now: Date) throws -> TLSIdentity? {
    guard let certificateData = try? Data(contentsOf: certificateURL),
          let privateKeyData = try? Data(contentsOf: privateKeyURL)
    else {
      return nil
    }
    let certificatePEM = String(decoding: certificateData, as: UTF8.self)
    let privateKeyPEM = String(decoding: privateKeyData, as: UTF8.self)
    let certificate = try Certificate(pemEncoded: certificatePEM)
    // Renew ahead of expiry so a long-running space never serves a dead cert.
    guard now.addingTimeInterval(7 * 24 * 3600) < certificate.notValidAfter else {
      return nil
    }
    guard case .isCertificateAuthority = try certificate.extensions.basicConstraints else {
      return nil
    }
    return TLSIdentity(certificatePEM: certificatePEM, privateKeyPEM: privateKeyPEM)
  }
}

extension TLSIdentity {
  /// Throws unless a TLS handshake can use this identity: its leaf and key
  /// parse, the key is on a named curve (P-256, P-384, P-521), RSA or
  /// Ed25519, and it is the leaf's own key. The TLS stack accepts some that
  /// fail here, an EC key with explicit curve parameters among them, and
  /// then fails every handshake (alert 80), so check before serving.
  public func validate() throws {
    let documents: [PEMDocument]
    do {
      documents = try PEMDocument.parseMultiple(pemString: certificatePEM)
    } catch {
      throw TLSIdentityError.unusable("the certificate is not PEM: \(error)")
    }
    guard let leaf = documents.first, leaf.discriminator == "CERTIFICATE" else {
      throw TLSIdentityError.unusable("the certificate file holds no PEM CERTIFICATE")
    }
    let certificate: Certificate
    do {
      certificate = try Certificate(derEncoded: leaf.derBytes)
    } catch {
      throw TLSIdentityError.unusable("the certificate's key is unsupported (\(error)); \(Self.supportedKeys)")
    }
    let key: Certificate.PrivateKey
    do {
      key = try Certificate.PrivateKey(pemEncoded: privateKeyPEM)
    } catch {
      throw TLSIdentityError.unusable("the private key is unsupported (\(error)); \(Self.supportedKeys)")
    }
    guard key.publicKey == certificate.publicKey else {
      throw TLSIdentityError.unusable("the private key is not the certificate's key")
    }
  }

  private static let supportedKeys =
    "use a key on a named curve (P-256, P-384 or P-521; no explicit curve parameters), RSA or Ed25519"
}

public enum TLSIdentityError: Error, Equatable, CustomStringConvertible {
  case unusable(String)

  public var description: String {
    switch self {
    case let .unusable(reason): reason
    }
  }
}

private func generalName(host: String) -> GeneralName {
  var v4 = in_addr()
  if inet_pton(AF_INET, host, &v4) == 1 {
    return withUnsafeBytes(of: v4) { .ipAddress(ASN1OctetString(contentBytes: ArraySlice($0))) }
  }
  var v6 = in6_addr()
  if inet_pton(AF_INET6, host, &v6) == 1 {
    return withUnsafeBytes(of: v6) { .ipAddress(ASN1OctetString(contentBytes: ArraySlice($0))) }
  }
  return .dnsName(host)
}
