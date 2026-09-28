#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Crypto
import ServeTLS
import Testing
import X509

@Suite struct TLSIdentityTests {
  let now = Date(timeIntervalSince1970: 1_780_000_000)

  @Test func selfSignedCoversDNSAndIPSubjectAlternativeNames() throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1", "::1", "wuhu.local"], now: now)
    let certificate = try Certificate(pemEncoded: identity.certificatePEM)
    let names = try #require(try certificate.extensions.subjectAlternativeNames)
    #expect(Array(names) == [
      .dnsName("localhost"),
      .ipAddress(.init(contentBytes: [127, 0, 0, 1])),
      .ipAddress(.init(contentBytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1])),
      .dnsName("wuhu.local"),
    ])
    #expect(certificate.notValidBefore < now)
    #expect(certificate.notValidAfter > now.addingTimeInterval(300 * 24 * 3600))
    #expect(certificate.issuer == certificate.subject)
  }

  @Test func validateRefusesAnIdentityNoHandshakeCanUse() throws {
    try TLSIdentity.selfSigned(hosts: ["*.space.test"], now: now).validate()
    let explicit = TLSIdentity(certificatePEM: explicitCurveCertificatePEM, privateKeyPEM: explicitCurveKeyPEM)
    let refusal = #expect(throws: TLSIdentityError.self) { try explicit.validate() }
    #expect(refusal?.description.contains("no explicit curve parameters") == true)
    let first = try TLSIdentity.selfSigned(hosts: ["*.space.test"], now: now)
    let other = try TLSIdentity.selfSigned(hosts: ["*.space.test"], now: now)
    let mismatched = TLSIdentity(certificatePEM: first.certificatePEM, privateKeyPEM: other.privateKeyPEM)
    #expect(throws: TLSIdentityError.unusable("the private key is not the certificate's key")) { try mismatched.validate() }
  }

  @Test func fingerprintIsStableForTheSameCertificate() throws {
    let key = P256.Signing.PrivateKey()
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost"], privateKey: key, now: now)
    let first = try identity.fingerprint()
    #expect(first == (try TLSIdentity.fingerprint(certificatePEM: identity.certificatePEM)))
    #expect(first.hasPrefix("sha256:"))
    #expect(first.count == "sha256:".count + 64)

    let other = try TLSIdentity.selfSigned(hosts: ["localhost"], now: now)
    #expect(try other.fingerprint() != first)
  }

  @Test func loadOrCreatePersistsAndReloadsTheSameIdentity() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let created = try await TLSIdentity.loadOrCreate(directory: directory, hosts: ["localhost"], now: now)
    let reloaded = try await TLSIdentity.loadOrCreate(directory: directory, hosts: ["localhost"], now: now)
    #expect(created.certificatePEM == reloaded.certificatePEM)
    #expect(created.privateKeyPEM == reloaded.privateKeyPEM)
  }

  @Test func loadOrCreateRegeneratesAnExpiringCertificate() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }

    let created = try await TLSIdentity.loadOrCreate(directory: directory, hosts: ["localhost"], now: now)
    let nearExpiry = now.addingTimeInterval(364 * 24 * 3600)
    let regenerated = try await TLSIdentity.loadOrCreate(directory: directory, hosts: ["localhost"], now: nearExpiry)
    #expect(created.certificatePEM != regenerated.certificatePEM)

    let reloaded = try await TLSIdentity.loadOrCreate(directory: directory, hosts: ["localhost"], now: nearExpiry)
    #expect(regenerated.certificatePEM == reloaded.certificatePEM)
  }
}

// A P-256 key and self-signed leaf spelled with explicit curve parameters
// (openssl ecparam -param_enc explicit): BoringSSL loads the pair, then
// fails every handshake with alert 80.
private let explicitCurveCertificatePEM = """
-----BEGIN CERTIFICATE-----
MIICdTCCAhugAwIBAgIUTKpO2ratpaSRsARx/3kj/FrNJrIwCgYIKoZIzj0EAwIw
FjEUMBIGA1UEAwwLKi5sb2NhbGhvc3QwHhcNMjYwOTI4MDMyODEzWhcNMzYwOTI1
MDMyODEzWjAWMRQwEgYDVQQDDAsqLmxvY2FsaG9zdDCCAUswggEDBgcqhkjOPQIB
MIH3AgEBMCwGByqGSM49AQECIQD/////AAAAAQAAAAAAAAAAAAAAAP//////////
/////zBbBCD/////AAAAAQAAAAAAAAAAAAAAAP///////////////AQgWsY12Ko6
k+ez671VdpiGvGUdBrDMU7D2O848PifSYEsDFQDEnTYIhucEk2pmeOETnSa3gZ9+
kARBBGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tK
fA+eFivOM1drMV7Oy7ZAaDe/UfUCIQD/////AAAAAP//////////vOb6racXnoTz
ucrC/GMlUQIBAQNCAATGYED7evZaLC5rinB8F08NV9z9439J6wLj7jS/qdYWBqMO
7LcjfueR8c0s/czkGSYrhtbkmhbUSyyA9Rb35opCo1MwUTAdBgNVHQ4EFgQUVnzQ
MTsXy7l6Cxiqe0c6X5k5uygwHwYDVR0jBBgwFoAUVnzQMTsXy7l6Cxiqe0c6X5k5
uygwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjOPQQDAgNIADBFAiBnXbQQdgot10UT
6jNF5ikBNRtihEoy4EcOgvSEYt/jKwIhAO6PSSMKW5wgqtvGIyyf2lFETzAEVema
lT/QidGsJF2V
-----END CERTIFICATE-----
"""

private let explicitCurveKeyPEM = """
-----BEGIN EC PRIVATE KEY-----
MIIBaAIBAQQguGediuoxpFBK78E3ZgR1Q+U38MrWceAr0c84dnwIAgCggfowgfcC
AQEwLAYHKoZIzj0BAQIhAP////8AAAABAAAAAAAAAAAAAAAA////////////////
MFsEIP////8AAAABAAAAAAAAAAAAAAAA///////////////8BCBaxjXYqjqT57Pr
vVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMVAMSdNgiG5wSTamZ44ROdJreBn36QBEEE
axfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n60p8D54W
K84zV2sxXs7LtkBoN79R9QIhAP////8AAAAA//////////+85vqtpxeehPO5ysL8
YyVRAgEBoUQDQgAExmBA+3r2Wiwua4pwfBdPDVfc/eN/SesC4+40v6nWFgajDuy3
I37nkfHNLP3M5BkmK4bW5JoW1EssgPUW9+aKQg==
-----END EC PRIVATE KEY-----
"""
