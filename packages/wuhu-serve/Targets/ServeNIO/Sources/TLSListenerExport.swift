#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import NIOCore
import NIOPosix
import Serve
import ServeTLS

extension ServeNIOServer {
  /// Owns a close-on-exec descriptor independently of the server. Keep it alive while borrowing descriptor; closing the server does not release this listener until the export is released too.
  public final class ListenerExport: Sendable {
    public let descriptor: Int32
    public let device: UInt64
    public let inode: UInt64

    init(host: String, port: Int) throws {
      let address = try SocketAddress.makeAddressResolvingHost(host, port: port)
      #if os(Linux)
        let descriptor = socket(Int32(address.protocol.rawValue), Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
      #else
        let descriptor = socket(Int32(address.protocol.rawValue), SOCK_STREAM, 0)
      #endif
      guard descriptor >= 0 else { throw IOError(errnoCode: errno, reason: "Cannot create TLS listener") }
      do {
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw IOError(errnoCode: errno, reason: "Cannot protect TLS listener") }
        var reuse: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
          throw IOError(errnoCode: errno, reason: "Cannot configure TLS listener")
        }
        let result = address.withSockAddr { address, size in
          #if os(Linux)
            Glibc.bind(descriptor, address, socklen_t(size))
          #else
            Darwin.bind(descriptor, address, socklen_t(size))
          #endif
        }
        guard result == 0, listen(descriptor, 256) == 0 else { throw IOError(errnoCode: errno, reason: "Cannot bind TLS listener") }
        var state = stat()
        guard fstat(descriptor, &state) == 0 else { throw IOError(errnoCode: errno, reason: "Cannot inspect TLS listener") }
        self.descriptor = descriptor
        device = UInt64(truncatingIfNeeded: state.st_dev)
        inode = UInt64(truncatingIfNeeded: state.st_ino)
      } catch { disposeListeningSocket(descriptor); throw error }
    }

    deinit { disposeListeningSocket(descriptor) }
  }

  public static func bindExportable(
    host: String = "127.0.0.1",
    port: Int,
    tls identity: TLSIdentity,
    subdomains: [String: TLSIdentity] = [:],
    options: ServeOptions = .init(),
    hooks: ServeNIOHooks = .init(),
    initiallyAccepting: Bool = true,
    eventLoopGroup: EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
    upgrading handler: @escaping UpgradingHandler,
  ) async throws -> (server: ServeNIOServer, listener: ListenerExport) {
    let listener: ListenerExport
    let descriptor: Int32
    do {
      listener = try ListenerExport(host: host, port: port)
      descriptor = fcntl(listener.descriptor, F_DUPFD_CLOEXEC, 0)
      guard descriptor >= 0 else { throw IOError(errnoCode: errno, reason: "Cannot duplicate TLS listener") }
    } catch { hooks.onStartupFailure(error); throw error }
    let server = try await adoptListeningSocket(descriptor, tls: identity, subdomains: subdomains, options: options, hooks: hooks, eventLoopGroup: eventLoopGroup, initiallyAccepting: initiallyAccepting, upgrading: handler)
    return (server, listener)
  }
}
