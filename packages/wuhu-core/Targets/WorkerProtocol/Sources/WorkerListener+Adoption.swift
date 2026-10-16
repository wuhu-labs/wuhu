#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import typealias Serve.Handler
import class ServeNIO.ServeNIOServer

extension WorkerListener {
  public struct InheritedIdentity: Sendable {
    let descriptor: SocketIdentity
    let path: SocketIdentity

    public var descriptorDevice: UInt64 { descriptor.device }
    public var descriptorInode: UInt64 { descriptor.inode }
    public var pathDevice: UInt64 { path.device }
    public var pathInode: UInt64 { path.inode }

    public init(descriptorDevice: UInt64, descriptorInode: UInt64, pathDevice: UInt64, pathInode: UInt64) {
      descriptor = SocketIdentity(device: descriptorDevice, inode: descriptorInode)
      path = SocketIdentity(device: pathDevice, inode: pathInode)
    }
  }

  /// Consumes the descriptor on success or refusal. Expected identities must come from the source before exec, not from the inherited descriptor. Starts without pathname-cleanup ownership until commitHandoff consumes the source capability.
  public static func adopt(_ descriptor: Int32, socket: String, expecting identity: InheritedIdentity, initiallyAccepting: Bool = true, handler: @escaping Handler) async throws -> Self {
    do {
      let flags = fcntl(descriptor, F_GETFD)
      guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
        throw WorkerProtocolError(.invalidConfiguration, message: "Cannot protect inherited worker listener")
      }
      try validateDirectory(socket: socket)
      var state = stat()
      guard fstat(descriptor, &state) == 0, state.st_mode & S_IFMT == S_IFSOCK,
            UInt64(truncatingIfNeeded: state.st_dev) == identity.descriptor.device, UInt64(truncatingIfNeeded: state.st_ino) == identity.descriptor.inode
      else {
        throw WorkerProtocolError(.invalidConfiguration, message: "Inherited worker listener descriptor identity mismatch")
      }
      #if os(Linux)
        let stream = Int32(SOCK_STREAM.rawValue)
      #else
        let stream = SOCK_STREAM
      #endif
      var type: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      var address = sockaddr_un()
      var addressSize = socklen_t(MemoryLayout<sockaddr_un>.size)
      let named = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &addressSize) }
      }
      let pathMatches = withUnsafeBytes(of: address.sun_path) { bytes in
        guard let end = bytes.firstIndex(of: 0) else { return false }
        return bytes[..<end].elementsEqual(socket.utf8)
      }
      guard getsockopt(descriptor, SOL_SOCKET, SO_TYPE, &type, &size) == 0, type == stream,
            isListening(descriptor),
            named == 0, address.sun_family == AF_UNIX, addressSize <= MemoryLayout<sockaddr_un>.size, pathMatches
      else {
        throw WorkerProtocolError(.invalidConfiguration, message: "Inherited worker descriptor is not the expected listening Unix stream socket")
      }
      guard lstat(socket, &state) == 0, state.st_mode & S_IFMT == S_IFSOCK,
            state.st_uid == getuid(), state.st_mode & 0o777 == 0o600,
            UInt64(truncatingIfNeeded: state.st_dev) == identity.path.device, UInt64(truncatingIfNeeded: state.st_ino) == identity.path.inode
      else {
        throw WorkerProtocolError(.invalidConfiguration, message: "Inherited worker listener path identity mismatch")
      }
    } catch {
      _ = close(descriptor)
      throw error
    }
    let retained: ListenerExport
    do { retained = try ListenerExport(duplicating: descriptor, identity: identity) }
    catch { _ = close(descriptor); throw error }
    let server: ServeNIOServer
    do {
      server = try await ServeNIOServer.adoptListeningSocket(descriptor, options: workerOptions, initiallyAccepting: initiallyAccepting, handler: handler)
    } catch {
      throw WorkerProtocolError(.unavailable, message: "Inherited worker listener adoption failed")
    }
    return Self(server: server, path: socket, identity: identity.path, retainedDescriptor: retained, initiallyAccepting: initiallyAccepting)
  }

  private static func isListening(_ descriptor: Int32) -> Bool {
    #if os(Linux)
      var value: Int32 = 0
      var size = socklen_t(MemoryLayout<Int32>.size)
      return getsockopt(descriptor, SOL_SOCKET, SO_ACCEPTCONN, &value, &size) == 0 && value != 0
    #else
      // Darwin refuses SO_ACCEPTCONN queries for Unix sockets; inspect the kernel socket options instead.
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      return proc_pidfdinfo(getpid(), descriptor, PROC_PIDFDSOCKETINFO, &info, size) == size
        && Int32(info.psi.soi_options) & SO_ACCEPTCONN != 0
    #endif
  }
}
