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
import Fetch
import FetchTunnel
import NIOCore
import NIOPosix
import struct OperationProtocol.OperationError
import typealias Serve.Handler

/// The machine's one rendezvous socket. The agent listens on `<machine directory>/ctl.sock`; every version-2 supervisor dials it,
/// proves its operation with the manifest nonce, and then serves its operation over a Fetch tunnel on that connection.
enum Rendezvous {
  static let protocolName = "wuhu-supervisor-rendezvous.v1"
  static let frameBytes = 64 * 1024
  static let handshakeTimeout: Duration = .seconds(2)
  static let redialFloor: Duration = .milliseconds(50)
  static let redialCeiling: Duration = .seconds(1)
  /// Darwin's `sun_path` minus its terminating NUL; NIO binds no longer path on any platform.
  static let maximumSocketPathBytes = 103

  struct Hello: Codable, Equatable, Sendable {
    var `protocol`: String
    var machine: String
    var operation: UUID
    var nonce: String
  }

  enum Refusal: String, Codable, Error, Sendable {
    case peerCredentials, unsupportedProtocol, malformedHello, unknownOperation, manifestVersion, machineMismatch, nonceMismatch
  }

  struct Reply: Codable, Equatable, Sendable {
    var accepted: Bool
    var refused: Refusal?
  }

  /// `ctl.sock` sits beside the operations directory, in the machine's private directory.
  static func socketPath(operationsDirectory: String) -> String {
    var root = operationsDirectory
    while root.count > 1, root.hasSuffix("/") { root.removeLast() }
    guard let slash = root.lastIndex(of: "/") else { return "/ctl.sock" }
    return String(root[..<slash]) + "/ctl.sock"
  }

  static func validateSocketPath(_ path: String) throws {
    guard path.utf8.count <= maximumSocketPathBytes else {
      throw OperationError(.invalidConfiguration, message: "Machine rendezvous socket \(path) is \(path.utf8.count) bytes; the Unix socket limit is \(maximumSocketPathBytes). Use a shorter home directory.", details: ["path": .string(path), "bytes": .number(Double(path.utf8.count)), "maximumBytes": .number(Double(maximumSocketPathBytes))])
    }
  }

  static func peerAllowed(_ uid: UInt32) -> Bool { uid == UInt32(getuid()) }

  static func noncesMatch(_ presented: String, _ expected: String) -> Bool {
    let left = Array(presented.utf8), right = Array(expected.utf8)
    guard left.count == right.count else { return false }
    var difference: UInt8 = 0
    for index in left.indices { difference |= left[index] ^ right[index] }
    return difference == 0
  }

  // MARK: Agent side

  /// Binds `ctl.sock` (after removing a stale socket the caller's lock entitles it to remove) and hands every admitted supervisor link to `admit`.
  static func listen(path: String, group: any EventLoopGroup) async throws -> NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never> {
    try validateSocketPath(path)
    let parent = String(path[..<path.lastIndex(of: "/")!])
    var state = stat()
    guard lstat(parent.isEmpty ? "/" : parent, &state) == 0, state.st_mode & S_IFMT == S_IFDIR, state.st_uid == getuid(), state.st_mode & 0o022 == 0 else {
      throw OperationError(.invalidConfiguration, message: "The directory holding \(path) must be this user's and not writable by others", details: ["path": .string(path)])
    }
    if lstat(path, &state) == 0 {
      guard state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFSOCK, unlink(path) == 0 else {
        throw OperationError(.invalidConfiguration, message: "\(path) exists and is not this user's stale socket", details: ["path": .string(path)])
      }
    }
    let server = try await ServerBootstrap(group: group).bind(unixDomainSocketPath: path) { channel in
      channel.eventLoop.makeCompletedFuture { try framed(channel) }
    }
    guard chmod(path, 0o600) == 0 else {
      try? await server.channel.close()
      throw OperationError(.invalidConfiguration, message: "Cannot make \(path) owner-private", details: ["path": .string(path)])
    }
    return server
  }

  static func accept(
    _ server: NIOAsyncChannel<NIOAsyncChannel<ByteBuffer, ByteBuffer>, Never>,
    registry: ExecSupervisorRegistry,
  ) async {
    try? await server.executeThenClose { inbound in
      try await withThrowingDiscardingTaskGroup { group in
        for try await connection in inbound {
          group.addTask { await admit(connection, registry: registry) }
        }
      }
    }
  }

  static func admit(_ channel: NIOAsyncChannel<ByteBuffer, ByteBuffer>, registry: ExecSupervisorRegistry) async {
    try? await channel.executeThenClose { inbound, outbound in
      let link = RendezvousLink(channel.channel, inbound, outbound)
      let hello: Hello
      do {
        guard peerAllowed(try await link.peerUID()) else { throw Refusal.peerCredentials }
        do { hello = try await link.receive(Hello.self) } catch { throw Refusal.malformedHello }
      } catch {
        try? await link.send(Reply(accepted: false, refused: error as? Refusal ?? .peerCredentials))
        return
      }
      let tunnel = try Tunnel(over: link.transport)
      let generation: UInt64
      do { generation = try await registry.link(hello, client: tunnel.client, abort: link.abort) }
      catch {
        try? await link.send(Reply(accepted: false, refused: error as? Refusal ?? .unknownOperation))
        return
      }
      do {
        try await link.send(Reply(accepted: true, refused: nil))
        try await tunnel.run()
      } catch {}
      await registry.unlink(hello.operation, generation: generation)
    }
  }

  // MARK: Supervisor side

  /// One dial: handshake, then serve the operation until the agent goes away. Returns whether the agent accepted this supervisor.
  static func dial(path: String, hello: Hello, group: any EventLoopGroup, handler: @escaping Handler) async throws -> Bool {
    let channel = try await ClientBootstrap(group: group).connect(unixDomainSocketPath: path) { channel in
      channel.eventLoop.makeCompletedFuture { try framed(channel) }
    }
    return try await channel.executeThenClose { inbound, outbound in
      let link = RendezvousLink(channel.channel, inbound, outbound)
      guard peerAllowed(try await link.peerUID()) else { throw Refusal.peerCredentials }
      try await link.send(hello)
      let reply = try await link.receive(Reply.self)
      guard reply.accepted else { throw reply.refused ?? .unknownOperation }
      try? await Tunnel.serve(over: link.transport, handler: handler)
      return true
    }
  }

  /// Redials `ctl.sock` with backoff for as long as the caller runs it; the command keeps running while the agent is away.
  static func redial(path: String, hello: Hello, group: any EventLoopGroup, handler: @escaping Handler) async {
    var delay = redialFloor
    while !Task.isCancelled {
      let accepted = (try? await dial(path: path, hello: hello, group: group, handler: handler)) ?? false
      delay = accepted ? redialFloor : min(delay * 2, redialCeiling)
      do { try await ContinuousClock().sleep(for: delay) } catch { return }
    }
  }

  private static func framed(_ channel: any Channel) throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(FrameDecoder()))
    try channel.pipeline.syncOperations.addHandler(MessageToByteHandler(FrameEncoder()))
    return try NIOAsyncChannel(wrappingChannelSynchronously: channel)
  }
}

/// One rendezvous connection: 4-byte big-endian length-prefixed frames of at most 64 KiB.
struct RendezvousLink: Sendable {
  let channel: any Channel
  let receiver: FrameReceiver
  let outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>

  init(_ channel: any Channel, _ inbound: NIOAsyncChannelInboundStream<ByteBuffer>, _ outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
    self.channel = channel; receiver = FrameReceiver(inbound); self.outbound = outbound
  }

  var abort: @Sendable () -> Void { { [channel] in channel.close(promise: nil) } }

  var transport: TunnelTransport {
    TunnelTransport(maxMessageBytes: Rendezvous.frameBytes, receive: { [receiver] in try await receiver.next() }, send: { [outbound] in try await outbound.write(ByteBuffer(bytes: $0)) }, abort: abort)
  }

  func send(_ value: some Encodable) async throws { try await outbound.write(ByteBuffer(bytes: JSONEncoder().encode(value))) }

  /// A handshake frame, closing the connection when it does not arrive in time.
  func receive<T: Decodable>(_ type: T.Type) async throws -> T {
    let watchdog = Task { [channel] in
      try await ContinuousClock().sleep(for: Rendezvous.handshakeTimeout)
      channel.close(promise: nil)
    }
    defer { watchdog.cancel() }
    guard let bytes = try await receiver.next() else { throw OperationError(.supervisorUnavailable, message: "Rendezvous closed during handshake") }
    return try JSONDecoder().decode(T.self, from: bytes)
  }

  func peerUID() async throws -> UInt32 {
    guard let provider = channel as? any SocketOptionProvider else { throw Rendezvous.Refusal.peerCredentials }
    #if os(Linux)
      // SOL_SOCKET / SO_PEERCRED: struct ucred { pid_t pid; uid_t uid; gid_t gid; }
      let credentials: LinuxPeerCredentials = try await provider.unsafeGetSocketOption(level: SocketOptionLevel(SOL_SOCKET), name: 17).get()
      return credentials.uid
    #else
      // SOL_LOCAL / LOCAL_PEERCRED: struct xucred, version 0.
      let credentials: DarwinPeerCredentials = try await provider.unsafeGetSocketOption(level: 0, name: 1).get()
      guard credentials.version == 0 else { throw Rendezvous.Refusal.peerCredentials }
      return credentials.uid
    #endif
  }
}

#if os(Linux)
  struct LinuxPeerCredentials: Sendable {
    var pid: Int32 = 0
    var uid: UInt32 = .max
    var gid: UInt32 = .max
  }
#else
  struct DarwinPeerCredentials: Sendable {
    var version: UInt32 = .max
    var uid: UInt32 = .max
    var groupCount: Int16 = 0
    var groups: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
  }
#endif

actor FrameReceiver {
  var iterator: NIOAsyncChannelInboundStream<ByteBuffer>.AsyncIterator
  var advancing = false
  init(_ inbound: NIOAsyncChannelInboundStream<ByteBuffer>) { iterator = inbound.makeAsyncIterator() }

  func next() async throws -> Bytes? {
    guard !advancing else { throw TunnelError.protocolViolation }
    advancing = true
    defer { advancing = false }
    var iterator = self.iterator
    let buffer = try await iterator.next(isolation: self)
    self.iterator = iterator
    return buffer.map { Data($0.readableBytesView) }
  }
}

struct FrameDecoder: ByteToMessageDecoder {
  typealias InboundOut = ByteBuffer

  mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
    guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt32.self) else { return .needMoreData }
    guard length <= Rendezvous.frameBytes else { throw TunnelError.corruptFraming }
    guard buffer.readableBytes >= 4 + Int(length) else { return .needMoreData }
    buffer.moveReaderIndex(forwardBy: 4)
    context.fireChannelRead(Self.wrapInboundOut(buffer.readSlice(length: Int(length))!))
    return .continue
  }

  mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
    while try decode(context: context, buffer: &buffer) == .continue {}
    return .needMoreData
  }
}

struct FrameEncoder: MessageToByteEncoder {
  typealias OutboundIn = ByteBuffer

  func encode(data: ByteBuffer, out: inout ByteBuffer) throws {
    guard data.readableBytes <= Rendezvous.frameBytes else { throw TunnelError.corruptFraming }
    out.writeInteger(UInt32(data.readableBytes))
    out.writeImmutableBuffer(data)
  }
}
