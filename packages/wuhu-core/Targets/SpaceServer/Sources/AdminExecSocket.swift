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
import Crypto
import NIOCore
import NIOPosix
import Synchronization

final class AdminExecSocket: Sendable {
  struct Message: Codable, Sendable { let id: UUID; var rollback = false; var query = false }
  let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
  let listenerDescriptor: Int32
  let path: String
  let device: UInt64
  let inode: UInt64

  static func location(folder: String, uid: UInt32, create: Bool) throws -> String {
    #if os(Linux)
      let root = "/tmp/wuhu-admin-" + String(uid)
    #else
      let root = "/private/tmp/wuhu-admin-" + String(uid)
    #endif
    if create, mkdir(root, 0o700) != 0, errno != EEXIST { throw AdminExecError.refused("adminSocketDirectory") }
    if create {
      let pinned = try ExecutionWorkerManifestStore.openDirectory(root)
      _ = close(pinned)
    }
    let key = SHA256.hash(data: Data(folder.utf8)).prefix(16).map { ("0" + String($0, radix: 16)).suffix(2) }.joined()
    return root + "/" + key + ".sock"
  }

  init(path: String) async throws {
    guard path.utf8.count < 104 else { throw AdminExecError.refused("adminSocketPath") }
    var state = stat()
    if lstat(path, &state) == 0 {
      guard state.st_mode & S_IFMT == S_IFSOCK, state.st_uid == geteuid() else { throw AdminExecError.refused("adminSocketIdentity") }
      do {
        let live = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connectTimeout(.seconds(1)).connect(unixDomainSocketPath: path).get()
        try? await live.close()
        throw AdminExecError.refused("alreadyEnabled")
      } catch let error as IOError where error.errnoCode == ECONNREFUSED {
        var current = stat()
        guard lstat(path, &current) == 0, current.st_ino == state.st_ino, current.st_dev == state.st_dev, unlink(path) == 0 else { throw AdminExecError.refused("adminSocketIdentity") }
      }
    }
    let descriptor = try Self.bindPrivateSocket(path)
    let owned = Mutex(false)
    let server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>
    do {
      server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
        .serverChannelInitializer { channel in
          owned.withLock { $0 = true }
          return channel.eventLoop.makeSucceededFuture(())
        }
        .bind(descriptor) { channel in
          channel.eventLoop.makeCompletedFuture { try Self.framed(channel) }
        }
    } catch { if !owned.withLock({ $0 }) { _ = close(descriptor) }; throw error }
    guard lstat(path, &state) == 0 else { try? await server.channel.close(); throw AdminExecError.refused("adminSocketIdentity") }
    self.server = server; self.path = path; listenerDescriptor = descriptor
    device = UInt64(truncatingIfNeeded: state.st_dev); inode = UInt64(truncatingIfNeeded: state.st_ino)
  }

  private static func bindPrivateSocket(_ path: String) throws -> Int32 {
    #if os(Linux)
      let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
    #else
      let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #endif
    guard descriptor >= 0 else { throw AdminExecError.refused("adminSocketIdentity") }
    do {
      guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else { throw AdminExecError.refused("descriptorInheritance") }
      let address = try SocketAddress(unixDomainSocketPath: path)
      let bound = address.withSockAddr { address, size in
        #if os(Linux)
          Glibc.bind(descriptor, address, socklen_t(size))
        #else
          Darwin.bind(descriptor, address, socklen_t(size))
        #endif
      }
      guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 16) == 0 else { throw AdminExecError.refused("adminSocketIdentity") }
      return descriptor
    } catch { _ = close(descriptor); throw error }
  }

  func run(allowedUIDs: Set<UInt32>, handle: @escaping @Sendable (UInt32, Message) async throws -> AdminExecController.Reply) async {
    try? await server.executeThenClose { inbound in
      await withDiscardingTaskGroup { group in
        do {
          for try await connection in inbound {
            group.addTask {
              try? await connection.executeThenClose { input, output in
                let uid = try await Self.peerUID(connection.channel)
                guard allowedUIDs.contains(uid) else {
                  try await output.write(ByteBuffer(bytes: JSONEncoder().encode(AdminExecController.Reply(id: UUID(), code: "deploymentAdminOnly", processID: getpid()))))
                  return
                }
                let timeout = Task { try await ContinuousClock().sleep(for: .seconds(2)); try? await connection.channel.close() }
                defer { timeout.cancel() }
                var iterator = input.makeAsyncIterator()
                guard let bytes = try await iterator.next() else { return }
                let message = try JSONDecoder().decode(Message.self, from: Data(bytes.readableBytesView))
                let reply: AdminExecController.Reply
                do { reply = try await handle(uid, message) }
                catch { reply = .init(id: message.id, code: AdminExecError.reason(error), processID: getpid()) }
                try await output.write(ByteBuffer(bytes: JSONEncoder().encode(reply)))
              }
            }
          }
        } catch {}
        group.cancelAll()
      }
    }
  }

  func shutdown() async {
    try? await server.channel.close()
    var state = stat()
    if lstat(path, &state) == 0, UInt64(truncatingIfNeeded: state.st_dev) == device, UInt64(truncatingIfNeeded: state.st_ino) == inode { _ = unlink(path) }
  }

  static func exchange(path: String, message: Message) async throws -> AdminExecController.Reply {
    let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton).connectTimeout(.seconds(1)).connect(unixDomainSocketPath: path) { channel in
      channel.eventLoop.makeCompletedFuture { try framed(channel) }
    }
    return try await channel.executeThenClose { input, output in
      let timeout = Task { try await ContinuousClock().sleep(for: .seconds(2)); try? await channel.channel.close() }
      defer { timeout.cancel() }
      try await output.write(ByteBuffer(bytes: JSONEncoder().encode(message)))
      var iterator = input.makeAsyncIterator()
      guard let bytes = try await iterator.next() else { throw AdminExecError.refused("adminPeerRefused") }
      return try JSONDecoder().decode(AdminExecController.Reply.self, from: Data(bytes.readableBytesView))
    }
  }

  private static func framed(_ channel: any Channel) throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(AdminExecDecoder()))
    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(AdminExecEncoder()))
    return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
  }

  static func peerUID(_ channel: any Channel) async throws -> UInt32 {
    guard let provider = channel as? any SocketOptionProvider else { throw AdminExecError.refused("adminPeerCredentials") }
    #if os(Linux)
      let peer: AdminExecLinuxPeer = try await provider.unsafeGetSocketOption(level: SocketOptionLevel(SOL_SOCKET), name: 17).get()
      return peer.uid
    #else
      let peer: AdminExecDarwinPeer = try await provider.unsafeGetSocketOption(level: 0, name: 1).get()
      guard peer.version == 0 else { throw AdminExecError.refused("adminPeerCredentials") }
      return peer.uid
    #endif
  }
}

#if os(Linux)
  private struct AdminExecLinuxPeer: Sendable { var pid: Int32 = 0; var uid: UInt32 = .max; var gid: UInt32 = .max }
#else
  private struct AdminExecDarwinPeer: Sendable {
    var version: UInt32 = .max
    var uid: UInt32 = .max
    var count: Int16 = 0
    var groups: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  }
#endif
private struct AdminExecDecoder: ByteToMessageDecoder {
  typealias InboundOut = ByteBuffer
  mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
    guard let count = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return .needMoreData }
    guard count > 0, count <= 4096 else { throw AdminExecError.refused("adminFrame") }
    guard buffer.readableBytes >= 4 + Int(count) else { return .needMoreData }
    buffer.moveReaderIndex(forwardBy: 4)
    context.fireChannelRead(Self.wrapInboundOut(buffer.readSlice(length: Int(count))!))
    return .continue
  }
}

private struct AdminExecEncoder: MessageToByteEncoder {
  typealias OutboundIn = ByteBuffer
  func encode(data: ByteBuffer, out: inout ByteBuffer) throws {
    guard data.readableBytes <= 4096 else { throw AdminExecError.refused("adminFrame") }
    out.writeInteger(UInt32(data.readableBytes)); out.writeImmutableBuffer(data)
  }
}
