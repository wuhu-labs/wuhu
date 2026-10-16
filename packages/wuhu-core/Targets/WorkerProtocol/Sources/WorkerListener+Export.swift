#if os(Linux)
  import Glibc
#else
  import Darwin
#endif

extension WorkerListener {
  /// Owns a close-on-exec duplicate. Keep this value alive through spawn and map its descriptor only into the intended child; never close or consume the borrowed descriptor directly.
  public final class ListenerExport: Sendable {
    public let descriptor: Int32
    public let identity: InheritedIdentity

    init(duplicating descriptor: Int32, identity: InheritedIdentity) throws {
      let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
      guard duplicate >= 0 else { throw WorkerProtocolError(.unavailable, message: "Cannot duplicate worker listener") }
      self.descriptor = duplicate
      self.identity = identity
    }

    deinit { _ = close(descriptor) }
  }

  /// Reconstruct only from a source finishHandoff result transported over the trusted handoff channel, never from the inherited socket itself.
  public struct CleanupOwnership: ~Copyable, Sendable {
    public let socket: String
    public let identity: InheritedIdentity

    public init(socket: String, identity: InheritedIdentity) {
      self.socket = socket
      self.identity = identity
    }
  }

  public func commitHandoff(_ ownership: consuming CleanupOwnership) throws {
    guard acceptance != .stopped, pathOwnership == .unowned, let retainedDescriptor,
          ownership.socket == path,
          ownership.identity.descriptorDevice == retainedDescriptor.identity.descriptorDevice,
          ownership.identity.descriptorInode == retainedDescriptor.identity.descriptorInode,
          ownership.identity.pathDevice == identity.device, ownership.identity.pathInode == identity.inode
    else { throw acceptanceError() }
    try validatePinnedPath()
    pathOwnership = .owned
  }

  public func pauseAccepting() async throws {
    guard acceptance == .accepting else { throw acceptanceError() }
    acceptance = .pausing
    do { try await server.setAcceptingConnections(false) }
    catch {
      if acceptance == .pausing { acceptance = .accepting }
      throw WorkerProtocolError(.unavailable, message: "Cannot pause worker listener")
    }
    guard acceptance == .pausing else { throw acceptanceError() }
    acceptance = .paused
  }

  public func resumeAccepting() async throws {
    guard acceptance == .paused else { throw acceptanceError() }
    acceptance = .resuming
    do { try await server.setAcceptingConnections(true) }
    catch {
      if acceptance == .resuming { acceptance = .paused }
      throw WorkerProtocolError(.unavailable, message: "Cannot resume worker listener")
    }
    guard acceptance == .resuming else { throw acceptanceError() }
    acceptance = .accepting
    if pathOwnership == .exportPending { pathOwnership = .owned }
  }

  public func exportListener() throws -> ListenerExport {
    guard acceptance == .paused, pathOwnership != .unowned, let retainedDescriptor else { throw acceptanceError() }
    try validatePinnedPath()
    let exported = try ListenerExport(duplicating: retainedDescriptor.descriptor, identity: retainedDescriptor.identity)
    pathOwnership = .exportPending
    return exported
  }

  private func validatePinnedPath() throws {
    var state = stat()
    guard lstat(path, &state) == 0, UInt64(truncatingIfNeeded: state.st_dev) == identity.device,
          UInt64(truncatingIfNeeded: state.st_ino) == identity.inode
    else { throw WorkerProtocolError(.invalidConfiguration, message: "Worker listener path changed before export") }
  }

  /// Relinquishes pathname cleanup. Deliver the returned capability only to the ready successor; loss in transit deliberately leaks the path rather than removing a live listener.
  public func finishHandoff() async throws -> CleanupOwnership {
    guard acceptance == .paused, pathOwnership == .exportPending, let retainedDescriptor else { throw acceptanceError() }
    try validatePinnedPath()
    let ownership = CleanupOwnership(socket: path, identity: retainedDescriptor.identity)
    acceptance = .stopped
    pathOwnership = .unowned
    self.retainedDescriptor = nil
    await server.shutdown()
    return ownership
  }

  private func acceptanceError() -> WorkerProtocolError {
    WorkerProtocolError(.invalidConfiguration, message: "Worker listener acceptance transition is not allowed")
  }

  static func createListener(at path: String) throws -> (descriptor: Int32, identity: InheritedIdentity) {
    #if os(Linux)
      let descriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
    #else
      let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard descriptor >= 0 else { throw WorkerProtocolError(.unavailable, message: "Cannot create worker listener") }
    var pathIdentity: SocketIdentity?
    do {
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
        throw WorkerProtocolError(.unavailable, message: "Cannot protect worker listener")
      }
      var address = sockaddr_un()
      address.sun_family = sa_family_t(AF_UNIX)
      #if !os(Linux)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
      #endif
      path.utf8CString.withUnsafeBytes { source in
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: source) }
      }
      let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          #if os(Linux)
            Glibc.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
          #else
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
          #endif
        }
      }
      var state = stat(), fdState = stat()
      guard result == 0, lstat(path, &state) == 0 else {
        throw WorkerProtocolError(.unavailable, message: "Cannot bind worker listener")
      }
      let identity = SocketIdentity(device: UInt64(truncatingIfNeeded: state.st_dev), inode: UInt64(truncatingIfNeeded: state.st_ino))
      pathIdentity = identity
      guard chmod(path, 0o600) == 0, listen(descriptor, 256) == 0, fstat(descriptor, &fdState) == 0 else {
        throw WorkerProtocolError(.unavailable, message: "Cannot initialize private worker listener")
      }
      return (descriptor, InheritedIdentity(descriptorDevice: UInt64(truncatingIfNeeded: fdState.st_dev), descriptorInode: UInt64(truncatingIfNeeded: fdState.st_ino), pathDevice: identity.device, pathInode: identity.inode))
    } catch {
      _ = close(descriptor)
      pathIdentity?.removeIfUnchanged(at: path)
      throw error
    }
  }
}
