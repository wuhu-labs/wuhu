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
  var stopped = false
  init(server: ServeNIOServer, path: String, identity: SocketIdentity) { self.server = server; self.path = path; self.identity = identity }

  public static func bind(socket: String, handler: @escaping Handler) async throws -> Self {
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
    let server: ServeNIOServer
    do {
      server = try await ServeNIOServer.bind(unixDomainSocketPath: socket, options: ServeOptions(maximumHeadBytes: 32 << 10, maximumHeaderLineBytes: 20 << 10, maximumBodyBytes: .max, requestBodyHighWatermarkBytes: 64 << 10, requestBodyLowWatermarkBytes: 16 << 10, requestReadInactivityTimeout: nil), handler: handler)
    } catch { throw WorkerProtocolError(.unavailable, message: "Worker socket bind failed: \(error)") }
    guard lstat(socket, &state) == 0, state.st_mode & S_IFMT == S_IFSOCK, state.st_uid == getuid() else {
      await server.shutdown()
      throw WorkerProtocolError(.invalidConfiguration, message: "Cannot identify bound worker socket")
    }
    let identity = SocketIdentity(device: UInt64(state.st_dev), inode: UInt64(state.st_ino))
    guard chmod(socket, 0o600) == 0 else {
      await server.shutdown()
      identity.removeIfUnchanged(at: socket)
      throw WorkerProtocolError(.invalidConfiguration, message: "Cannot make worker socket owner-private")
    }
    return Self(server: server, path: socket, identity: identity)
  }

  public func run() async {
    await server.runUntilCancelled()
    await shutdown()
  }

  public func shutdown() async {
    guard !stopped else { return }
    stopped = true
    await server.shutdown()
    identity.removeIfUnchanged(at: path)
  }
}

struct SocketIdentity: Sendable {
  let device: UInt64
  let inode: UInt64

  func removeIfUnchanged(at path: String) {
    var current = stat()
    guard lstat(path, &current) == 0, UInt64(current.st_dev) == device, UInt64(current.st_ino) == inode else { return }
    _ = unlink(path)
  }
}
