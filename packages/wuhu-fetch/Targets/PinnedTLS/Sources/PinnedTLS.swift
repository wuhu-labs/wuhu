#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Crypto
import NIOCore
import NIOPosix
import NIOSSL
import Synchronization

public enum PinnedTLSError: Error, Equatable, Sendable {
  case emptyPeerCertificateChain
  case invalidPinnedCertificate
  case handshakeTimedOut
}

public enum PinnedTLS {
  public static func fingerprint(certificateDER: some Sequence<UInt8>) -> String {
    let digest = SHA256.hash(data: Data(certificateDER))
    var hex = "sha256:"
    for byte in digest {
      hex += byte < 16 ? "0" + String(byte, radix: 16) : String(byte, radix: 16)
    }
    return hex
  }

  public static func fingerprint(certificateDERBase64: String) throws -> String {
    guard let der = Data(base64Encoded: certificateDERBase64) else {
      throw PinnedTLSError.invalidPinnedCertificate
    }
    return self.fingerprint(certificateDER: der)
  }

  public static func verification(pinnedFingerprint: String) -> NIOSSLCustomVerificationCallback {
    { certificates, promise in
      guard let leaf = certificates.first, let der = try? leaf.toDERBytes() else {
        promise.succeed(.failed)
        return
      }
      promise.succeed(self.fingerprint(certificateDER: der) == pinnedFingerprint ? .certificateVerified : .failed)
    }
  }

  public static func clientHandler(
    pinnedFingerprint: String,
    serverHostname: String?,
  ) throws -> NIOSSLClientHandler {
    var configuration = TLSConfiguration.makeClientConfiguration()
    // The pin is the identity: the verification callback accepts exactly the
    // pinned certificate, so trust roots play no part — and hostname checks
    // must stay off, because NIOSSL validates hostnames post-handshake even
    // when a custom callback replaced chain verification.
    configuration.certificateVerification = .noHostnameVerification
    configuration.trustRoots = .certificates([])
    configuration.applicationProtocols = ["http/1.1"]
    return try NIOSSLClientHandler(
      context: NIOSSLContext(configuration: configuration),
      serverHostname: serverHostname,
      customVerificationCallback: self.verification(pinnedFingerprint: pinnedFingerprint),
    )
  }

  /// The leaf certificate a server presents, base64 DER. The SNI name is
  /// `serverName` when given, else `host` unless it is an IP literal.
  public static func probeCertificate(
    host: String,
    port: Int,
    serverName: String? = nil,
    timeout: TimeAmount? = .seconds(10),
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
  ) async throws -> String {
    let loop = eventLoopGroup.next()
    let capture = loop.makePromise(of: [UInt8].self)
    // The verification callback, the handshake deadline, and the connect
    // failure path race to resolve the capture; only the first may land.
    let completed = Mutex(false)
    let complete: @Sendable (Result<[UInt8], any Error>) -> Void = { result in
      let first = completed.withLock { done in
        if done { return false }
        done = true
        return true
      }
      if first {
        capture.completeWith(result)
      }
    }
    var configuration = TLSConfiguration.makeClientConfiguration()
    configuration.certificateVerification = .noHostnameVerification
    let context = try NIOSSLContext(configuration: configuration)
    let serverHostname = serverName ?? ((try? SocketAddress(ipAddress: host, port: port)) == nil ? host : nil)
    do {
      let channel: Channel = try await ClientBootstrap(group: eventLoopGroup)
        .connect(host: host, port: port) { channel in
          channel.eventLoop.makeCompletedFuture {
            try channel.pipeline.syncOperations.addHandler(
              NIOSSLClientHandler(context: context, serverHostname: serverHostname) { certificates, verification in
                guard let leaf = certificates.first, let der = try? leaf.toDERBytes() else {
                  complete(.failure(PinnedTLSError.emptyPeerCertificateChain))
                  verification.succeed(.failed)
                  return
                }
                complete(.success(der))
                verification.succeed(.certificateVerified)
              },
            )
            return channel
          }
        }
      if let timeout {
        // A server that accepts TCP but never speaks TLS must not hang the
        // probe: the deadline bounds the handshake wait, not just the connect.
        let deadline = loop.scheduleTask(in: timeout) {
          complete(.failure(PinnedTLSError.handshakeTimedOut))
          channel.close(promise: nil)
        }
        capture.futureResult.whenComplete { _ in deadline.cancel() }
      }
      let der = try await capture.futureResult.get()
      try? await channel.close()
      return Data(der).base64EncodedString()
    } catch {
      complete(.failure(error))
      throw error
    }
  }
}
