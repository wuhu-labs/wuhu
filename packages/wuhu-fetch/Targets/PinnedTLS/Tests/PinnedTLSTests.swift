#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import NIOCore
import NIOPosix
import NIOSSL
import PinnedTLS
import Testing

@Suite struct PinnedTLSTests {
  @Test func fingerprintIsLowercaseHexOverDER() throws {
    let fingerprint = PinnedTLS.fingerprint(certificateDER: [1, 2, 3])
    #expect(fingerprint.hasPrefix("sha256:"))
    #expect(fingerprint.count == "sha256:".count + 64)
    #expect(fingerprint == PinnedTLS.fingerprint(certificateDER: Data([1, 2, 3])))
    #expect(try PinnedTLS.fingerprint(certificateDERBase64: Data([1, 2, 3]).base64EncodedString()) == fingerprint)
  }

  @Test func rejectsGarbagePins() {
    #expect(throws: PinnedTLSError.invalidPinnedCertificate) {
      _ = try PinnedTLS.fingerprint(certificateDERBase64: "not base64!!!")
    }
  }

  @Test func probesTimeOutAgainstAListenerThatAcceptsTCPButNeverSpeaksTLS() async throws {
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .bind(host: "127.0.0.1", port: 0)
      .get()
    let port = try #require(server.localAddress?.port)

    await #expect(throws: PinnedTLSError.handshakeTimedOut) {
      _ = try await PinnedTLS.probeCertificate(host: "127.0.0.1", port: port, timeout: .milliseconds(200))
    }
    await #expect(throws: SystemTrustError.self) {
      try await SystemTrust.validate(host: "127.0.0.1", port: port, anchors: .platformDefault, timeout: .milliseconds(200))
    }
    try? await server.close().get()
  }

  @Test func refusedConnectFailsValidateWithoutLeakingTheHandshakePromise() async throws {
    // A refused connect tears the channel down before it ever goes active —
    // the same condition a happy-eyeballs loser hits — so only handlerRemoved
    // can settle the handshake promise.
    let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .bind(host: "127.0.0.1", port: 0)
      .get()
    let port = try #require(server.localAddress?.port)
    try await server.close().get()

    await #expect(throws: (any Error).self) {
      try await SystemTrust.validate(host: "127.0.0.1", port: port, anchors: .platformDefault)
    }
  }

  @Test func verificationAcceptsExactlyThePinnedLeaf() async throws {
    let pinned = try sampleCertificate()
    let fingerprint = PinnedTLS.fingerprint(certificateDER: try pinned.toDERBytes())

    #expect(try await verified(fingerprint: fingerprint, presented: [pinned]))
    #expect(!(try await verified(fingerprint: PinnedTLS.fingerprint(certificateDER: [1, 2, 3]), presented: [pinned])))
    #expect(!(try await verified(fingerprint: fingerprint, presented: [])))
  }
}

private func verified(fingerprint: String, presented: [NIOSSLCertificate]) async throws -> Bool {
  let verification = PinnedTLS.verification(pinnedFingerprint: fingerprint)
  let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: NIOSSLVerificationResult.self)
  verification(presented, promise)
  switch try await promise.futureResult.get() {
  case .certificateVerified: return true
  case .failed: return false
  }
}

private func sampleCertificate() throws -> NIOSSLCertificate {
  let pem = """
  -----BEGIN CERTIFICATE-----
  MIIBgTCCASegAwIBAgIUNIrgijD19RtHVGxBCYcnIt6nH24wCgYIKoZIzj0EAwIw
  FjEUMBIGA1UEAwwLc2FtcGxlLnRlc3QwHhcNMjYwNzA3MDU0MjEyWhcNMzYwNzA0
  MDU0MjEyWjAWMRQwEgYDVQQDDAtzYW1wbGUudGVzdDBZMBMGByqGSM49AgEGCCqG
  SM49AwEHA0IABE/tzGt6cwqYUYhYc7SvZ6WHJhijECGsbtevfvUc3AKRKf8FYnyU
  Sz9McESy9nFcz6vDPATmFyAlrXFgXFE7xh2jUzBRMB0GA1UdDgQWBBQXUH8wt6jA
  gRFPqMmuelHK1Z27ZDAfBgNVHSMEGDAWgBQXUH8wt6jAgRFPqMmuelHK1Z27ZDAP
  BgNVHRMBAf8EBTADAQH/MAoGCCqGSM49BAMCA0gAMEUCIGWL8ypaHw7MAZ87wbV+
  AREgrOfa1zuz+yL9zOExq6p4AiEAkLIEwuQl9oPlVwypPb7NYqSTwy1Q9/wDnHNA
  RGFDrdU=
  -----END CERTIFICATE-----
  """
  return try NIOSSLCertificate(bytes: Array(pem.utf8), format: .pem)
}
