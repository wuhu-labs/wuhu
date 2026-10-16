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
import NIOCore
import NIOPosix
import typealias Serve.Handler
import struct Serve.ServeOptions
import class ServeNIO.ServeNIOServer

public actor WorkerListener {
  let server: ServeNIOServer
  let path: String
  let identity: SocketIdentity
  enum Acceptance { case accepting, pausing, paused, resuming, stopped }
  enum PathOwnership { case owned, exportPending, unowned }
  var pathOwnership = PathOwnership.unowned
  var acceptance = Acceptance.accepting
  var retainedDescriptor: ListenerExport?
  init(server: ServeNIOServer, path: String, identity: SocketIdentity, retainedDescriptor: ListenerExport, initiallyAccepting: Bool = true) {
    self.server = server; self.path = path; self.identity = identity; self.retainedDescriptor = retainedDescriptor
    acceptance = initiallyAccepting ? .accepting : .paused
  }

  public static func bind(socket: String, handler: @escaping Handler) async throws -> Self {
    try validateDirectory(socket: socket)
    var state = stat()
    if lstat(socket, &state) == 0 {
      guard state.st_mode & S_IFMT == S_IFSOCK, state.st_uid == getuid(), state.st_mode & 0o777 == 0o600 else {
        throw WorkerProtocolError(.invalidConfiguration, message: "Existing worker path is not an owner-private socket")
      }
      do {
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
          .connectTimeout(.seconds(1)).connect(unixDomainSocketPath: socket).get()
        try? await channel.close()
        throw WorkerProtocolError(.invalidConfiguration, message: "Worker socket has a live listener")
      } catch let error as IOError where error.errnoCode == ECONNREFUSED {
        var current = stat()
        guard lstat(socket, &current) == 0, current.st_ino == state.st_ino, current.st_dev == state.st_dev,
              unlink(socket) == 0
        else {
          throw WorkerProtocolError(.invalidConfiguration, message: "Stale worker socket changed during removal")
        }
      } catch let error as WorkerProtocolError { throw error }
      catch { throw WorkerProtocolError(.unavailable, message: "Could not determine whether worker socket is stale") }
    } else if errno != ENOENT {
      throw WorkerProtocolError(.invalidConfiguration, message: "Cannot inspect worker socket path")
    }
    let bound = try createListener(at: socket)
    do {
      let listener = try await adopt(bound.descriptor, socket: socket, expecting: bound.identity, handler: handler)
      await listener.claimBoundPath()
      return listener
    } catch {
      bound.identity.path.removeIfUnchanged(at: socket)
      throw error
    }
  }

  static var workerOptions: ServeOptions {
    ServeOptions(maximumHeadBytes: 32 << 10, maximumHeaderLineBytes: 20 << 10, maximumBodyBytes: .max, requestBodyHighWatermarkBytes: 64 << 10, requestBodyLowWatermarkBytes: 16 << 10, requestReadInactivityTimeout: nil)
  }

  static func validateDirectory(socket: String) throws {
    guard socket.hasPrefix("/"), !socket.utf8.contains(0), socket.utf8.count < 104 else {
      throw WorkerProtocolError(.invalidConfiguration, message: "Invalid private worker socket path")
    }
    var state = stat()
    let directory = URL(fileURLWithPath: socket).deletingLastPathComponent().path
    guard lstat(directory, &state) == 0, state.st_uid == getuid(), state.st_mode & 0o777 == 0o700,
          state.st_mode & S_IFMT == S_IFDIR
    else {
      throw WorkerProtocolError(.invalidConfiguration, message: "Worker socket directory must be owned by this user and mode 0700")
    }
  }

  public func run() async {
    await server.runUntilCancelled()
    await shutdown()
  }

  private func claimBoundPath() { pathOwnership = .owned }

  public func shutdown() async {
    guard acceptance != .stopped else { return }
    acceptance = .stopped
    let removesPath = pathOwnership == .owned
    pathOwnership = .unowned
    retainedDescriptor = nil
    await server.shutdown()
    if removesPath { identity.removeIfUnchanged(at: path) }
  }
}

struct SocketIdentity: Sendable {
  let device: UInt64
  let inode: UInt64

  func removeIfUnchanged(at path: String) {
    var current = stat()
    guard lstat(path, &current) == 0, UInt64(truncatingIfNeeded: current.st_dev) == device, UInt64(truncatingIfNeeded: current.st_ino) == inode else { return }
    _ = unlink(path)
  }
}
