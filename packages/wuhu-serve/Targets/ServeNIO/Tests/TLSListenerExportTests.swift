#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import AsyncHTTPClient
import NIOCore
import Serve
import ServeNIO
import ServeTLS
import Synchronization
import Testing

@Suite struct TLSListenerExportTests {
  @Test func exportableBindInitiallyPausedDoesNotAcceptBeforeEnable() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let accepts = Mutex(0)
    let source = try await ServeNIOServer.bindExportable(port: 0, tls: identity, hooks: .init(onDidAcceptConnection: { _ in accepts.withLock { $0 += 1 } }), initiallyAccepting: false, upgrading: { _ in .response(.text("enabled")) })
    let port = try #require(source.server.boundAddress.port)
    let queued = try connectTCP(port: port)
    defer { _ = close(queued) }
    try await ContinuousClock().sleep(for: .milliseconds(100))
    #expect(accepts.withLock { $0 } == 0)
    do {
      try await source.server.setAcceptingConnections(true)
      try await requestTLS(port: port, http1: false, expected: "enabled")
    } catch { await source.server.shutdown(); throw error }
    await source.server.shutdown()
  }

  @Test func gatedAdoptionPreservesListenerAndTLSProtocols() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let source = try await ServeNIOServer.bindExportable(port: 0, tls: identity, upgrading: { _ in .response(.text("source")) })
    let port = try #require(source.server.boundAddress.port)
    try await source.server.setAcceptingConnections(false)
    let descriptor = try duplicate(source.listener)
    let accepts = Mutex(0)
    let successor = try await ServeNIOServer.adoptListeningSocket(
      descriptor, tls: identity, hooks: .init(onDidAcceptConnection: { _ in accepts.withLock { $0 += 1 } }), initiallyAccepting: false,
      upgrading: { request in .response(.text("\(request.url.scheme ?? "?") successor")) },
    )
    #expect(successor.boundAddress == source.server.boundAddress)
    #expect(fcntl(descriptor, F_GETFD) & FD_CLOEXEC != 0)
    #expect(fcntl(source.listener.descriptor, F_GETFD) & FD_CLOEXEC != 0)
    try sameSocket(source.listener, descriptor)
    let queued = try connectTCP(port: port)
    defer { _ = close(queued) }
    try await ContinuousClock().sleep(for: .milliseconds(100))
    #expect(accepts.withLock { $0 } == 0)
    await source.server.shutdown()
    try sameSocket(source.listener, descriptor)
    try await successor.setAcceptingConnections(true)
    do {
      try await requestTLS(port: port, http1: false, expected: "https successor")
      try await requestTLS(port: port, http1: true, expected: "https successor")
    } catch { await successor.shutdown(); throw error }
    await successor.shutdown()
    try sameSocket(source.listener, source.listener.descriptor)
  }

  @Test func failedTLSInitializationClosesImportAndSourceResumes() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost", "127.0.0.1"])
    let port: Int
    do {
      let source = try await ServeNIOServer.bindExportable(port: 0, tls: identity, upgrading: { _ in .response(.text("source")) })
      port = try #require(source.server.boundAddress.port)
      try await source.server.setAcceptingConnections(false)
      let descriptor = try duplicate(source.listener)
      let failures = Mutex(0), binds = Mutex(0)
      do {
        let server = try await ServeNIOServer.adoptListeningSocket(
          descriptor, tls: .init(certificatePEM: "invalid", privateKeyPEM: "invalid"),
          hooks: .init(onDidBind: { _ in binds.withLock { $0 += 1 } }, onStartupFailure: { _ in failures.withLock { $0 += 1 } }),
          upgrading: { _ in .response(.text("unexpected")) },
        )
        await server.shutdown()
        Issue.record("Invalid TLS accepted")
      } catch {}
      #expect(failures.withLock { $0 } == 1)
      #expect(binds.withLock { $0 } == 0)
      try await source.server.setAcceptingConnections(true)
      do { try await requestTLS(port: port, http1: false, expected: "source") }
      catch { await source.server.shutdown(); throw error }
      await source.server.shutdown()
    }
    // A leaked listener keeps the port bound; a reused FD number or Darwin socket inode is not a reliable close oracle.
    let replacement = try await ServeNIOServer.bind(port: port) { _ in .text("replacement") }
    await replacement.shutdown()
  }

  @Test func exportedAdoptionPreservesSNISelection() async throws {
    let authority = try TLSIdentity.selfSigned(hosts: ["authority"])
    let bare = try TLSIdentity.issued(hosts: ["space.test"], by: authority)
    let wildcard = try TLSIdentity.issued(hosts: ["*.space.test"], by: authority)
    let source = try await ServeNIOServer.bindExportable(port: 0, tls: bare, subdomains: ["Space.Test": wildcard], upgrading: { _ in .response(.text("source")) })
    try await source.server.setAcceptingConnections(false)
    let successor = try await ServeNIOServer.adoptListeningSocket(duplicate(source.listener), tls: bare, subdomains: ["Space.Test": wildcard], upgrading: { _ in .response(.text("successor")) })
    await source.server.shutdown()
    do {
      let port = try #require(successor.boundAddress.port)
      #expect(try await handshakeLeaf(port: port, serverName: "alice.space.test") == wildcard.fingerprint())
      #expect(try await handshakeLeaf(port: port, serverName: "space.test") == bare.fingerprint())
      #expect(try await handshakeLeaf(port: port, serverName: "a.b.space.test") == bare.fingerprint())
    } catch { await successor.shutdown(); throw error }
    await successor.shutdown()
  }

  @Test func exportKeepsPortBoundUntilReleased() async throws {
    let identity = try TLSIdentity.selfSigned(hosts: ["localhost"])
    let port: Int
    do {
      let source = try await ServeNIOServer.bindExportable(port: 0, tls: identity, upgrading: { _ in .response(.text("source")) })
      port = try #require(source.server.boundAddress.port)
      await source.server.shutdown()
      try sameSocket(source.listener, source.listener.descriptor)
      do {
        let unexpected = try await ServeNIOServer.bind(port: port) { _ in .text("unexpected") }
        await unexpected.shutdown()
        Issue.record("Released the port while an export still owns the listener")
      } catch let error as IOError { #expect(error.errnoCode == EADDRINUSE) }
      try sameSocket(source.listener, source.listener.descriptor)
    }
    let replacement = try await ServeNIOServer.bind(port: port) { _ in .text("replacement") }
    await replacement.shutdown()
  }
}

private func duplicate(_ listener: ServeNIOServer.ListenerExport) throws -> Int32 {
  let descriptor = fcntl(listener.descriptor, F_DUPFD_CLOEXEC, 0)
  try #require(descriptor >= 0)
  return descriptor
}

private func sameSocket(_ listener: ServeNIOServer.ListenerExport, _ descriptor: Int32) throws {
  var state = stat()
  try #require(fstat(descriptor, &state) == 0)
  #expect(UInt64(truncatingIfNeeded: state.st_dev) == listener.device)
  #expect(UInt64(truncatingIfNeeded: state.st_ino) == listener.inode)
}

private func connectTCP(port: Int) throws -> Int32 {
  #if os(Linux)
    let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
  #else
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
  #endif
  try #require(descriptor >= 0)
  do {
    try #require(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0)
    let address = try SocketAddress(ipAddress: "127.0.0.1", port: port)
    let result = address.withSockAddr { connect(descriptor, $0, socklen_t($1)) }
    try #require(result == 0)
    return descriptor
  } catch { _ = close(descriptor); throw error }
}

private func requestTLS(port: Int, http1: Bool, expected: String) async throws {
  var configuration = HTTPClient.Configuration()
  configuration.tlsConfiguration = .makeClientConfiguration()
  configuration.tlsConfiguration?.certificateVerification = .none
  configuration.httpVersion = http1 ? .http1Only : .automatic
  let client = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
  do {
    let response = try await client.execute(HTTPClientRequest(url: "https://127.0.0.1:\(port)/"), timeout: .seconds(10))
    #expect(response.version == (http1 ? .http1_1 : .http2))
    var body = try await response.body.collect(upTo: 1 << 16)
    #expect(body.readString(length: body.readableBytes) == expected)
    try await client.shutdown()
  } catch { try? await client.shutdown(); throw error }
}
