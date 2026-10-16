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
@testable import ServeNIO
import Synchronization
import Testing

@Suite struct ListeningSocketAdoptionTests {
  @Test(arguments: [false, true]) func startupFailureClosesExactlyOnce(afterChannelCreation: Bool) async throws {
    let directory = "/tmp/adoption-" + UUID().uuidString
    try #require(mkdir(directory, 0o700) == 0)
    let path = directory + "/owner.sock"
    defer { _ = unlink(path); _ = rmdir(directory) }
    let descriptor = try listeningSocket(path: path)
    var descriptorBefore = stat()
    try #require(fstat(descriptor, &descriptorBefore) == 0)
    var before = stat()
    try #require(lstat(path, &before) == 0)
    let starts = Mutex<[Int32]>([])
    let initializations = Mutex(0)
    let disposals = Mutex<[Int32]>([])
    let disposalResults = Mutex<[Int32]>([])
    let failures = Mutex(0)
    let binds = Mutex(0)
    let group = MultiThreadedEventLoopGroup.singleton
    do {
      let server = try await ServeNIOServer.adoptListeningSocket(
        descriptor,
        hooks: .init(onDidBind: { _ in binds.withLock { $0 += 1 } }, onStartupFailure: { _ in failures.withLock { $0 += 1 } }),
        eventLoopGroup: group,
        handler: { _ in .text("unexpected") },
        start: { bootstrap, fd in
          starts.withLock { $0.append(fd) }
          if afterChannelCreation { return bootstrap.withBoundSocket(fd) }
          return bootstrap.enableMPTCP(true).withBoundSocket(fd)
        },
        initialize: { channel in
          initializations.withLock { $0 += 1 }
          return channel.eventLoop.makeFailedFuture(IOError(errnoCode: EINVAL, reason: "fixture startup after channel"))
        },
        dispose: { fd in
          disposals.withLock { $0.append(fd) }
          disposalResults.withLock { $0.append(close(fd)) }
        },
      )
      await server.shutdown()
      Issue.record("Failed startup returned a server")
    } catch let error as IOError {
      #expect(afterChannelCreation && error.errnoCode == EINVAL)
    } catch let error as ChannelError {
      #expect(!afterChannelCreation && error == .operationUnsupported)
    }
    #expect(starts.withLock { $0 } == [descriptor])
    #expect(initializations.withLock { $0 } == (afterChannelCreation ? 1 : 0))
    #expect(disposals.withLock { $0 } == (afterChannelCreation ? [] : [descriptor]))
    #expect(disposalResults.withLock { $0 } == (afterChannelCreation ? [] : [0]))
    #expect(failures.withLock { $0 } == 1)
    #expect(binds.withLock { $0 } == 0)
    var descriptorAfter = stat()
    if fstat(descriptor, &descriptorAfter) == 0 {
      #expect(descriptorAfter.st_dev != descriptorBefore.st_dev || descriptorAfter.st_ino != descriptorBefore.st_ino)
    } else {
      #expect(errno == EBADF)
    }
    var after = stat()
    #expect(lstat(path, &after) == 0)
    #expect(after.st_dev == before.st_dev && after.st_ino == before.st_ino)
  }
}

private func listeningSocket(path: String) throws -> Int32 {
  #if os(Linux)
    let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
  #else
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
  #endif
  try #require(descriptor >= 0)
  do {
    try #require(fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0)
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    #if !os(Linux)
      address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    path.utf8CString.withUnsafeBytes { source in
      withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: source) }
    }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    try #require(result == 0 && chmod(path, 0o600) == 0 && listen(descriptor, 16) == 0)
    return descriptor
  } catch { _ = close(descriptor); throw error }
}
