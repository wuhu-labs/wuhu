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
import class AsyncHTTPClient.HTTPClient
import Fetch
import FetchAsyncHTTPClient
import NIOCore
import NIOPosix
import Synchronization
import Testing
import WorkerProtocol

@Test func unixTransportStreamsWhileControlRemainsAvailable() async throws {
  let directory = "/tmp/worker-" + UUID().uuidString
  #expect(mkdir(directory, 0o700) == 0)
  defer { _ = rmdir(directory) }
  let socket = directory + "/owner.sock"
  let (stream, continuation) = AsyncStream<Bytes>.makeStream(bufferingPolicy: .bufferingOldest(1))
  let uploaded = Mutex(0)
  let endpoint = try WorkerEndpoint(token: "one-space-incarnation", hello: .init(release: "parent"), invoke: { $0.payload }, upload: { _, body in
    for try await chunk in body.asyncBytes() { uploaded.withLock { $0 += chunk.count } }
  }, download: { _ in .stream(stream) })
  let listener = try await WorkerListener.bind(socket: socket, handler: endpoint.handler)
  var configuration = HTTPClient.Configuration()
  configuration.redirectConfiguration = .disallow
  let control = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
  let bytes = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton), configuration: configuration)
  let result: Result<Void, any Error>
  var stage = "hello"
  do {
    let client = try WorkerClient(socket: socket, token: "one-space-incarnation", control: .asyncHTTPClient(control, timeout: .seconds(10)), bytes: .asyncHTTPClient(bytes, timeout: .seconds(10)))
    _ = try await client.negotiate(.init(release: "different-release"))
    stage = "download head"
    let response = try await client.stream(.init(operation: "machine.output"))
    continuation.yield(Data("first".utf8))
    var reader = response.asyncBytes().makeAsyncIterator()
    stage = "first download chunk"
    #expect(try await reader.next() == Data("first".utf8))
    stage = "concurrent control reply"
    #expect(try await client.call(.init(operation: "session.interrupt", payload: "control")) == "control")
    continuation.yield(Data("last".utf8))
    continuation.finish()
    stage = "last download chunk"
    #expect(try await reader.next() == Data("last".utf8))
    stage = "download EOF"
    #expect(try await reader.next() == nil)
    let chunks = AsyncStream<Bytes> { continuation in
      for _ in 0 ..< 128 { continuation.yield(Data(repeating: 42, count: 32768)) }
      continuation.finish()
    }
    stage = "upload acknowledgement"
    try await client.upload(.init(operation: "file.write"), body: .stream(chunks))
    #expect(uploaded.withLock { $0 } == 4 << 20)
    var state = stat()
    #expect(lstat(socket, &state) == 0)
    #expect(state.st_mode & 0o777 == 0o600)
    result = .success(())
  } catch { Issue.record("Unix transport failed during \(stage)"); result = .failure(error) }
  await listener.shutdown()
  try await control.shutdown()
  try await bytes.shutdown()
  try result.get()
}

@Test func privateSocketAdmissionRefusesUnsafeDirectoryAndReplacement() async throws {
  let directory = "/tmp/worker-" + UUID().uuidString
  #expect(mkdir(directory, 0o755) == 0)
  defer { _ = rmdir(directory) }
  let socket = directory + "/owner.sock"
  await #expect(throws: WorkerProtocolError.self) { try await WorkerListener.bind(socket: socket) { _ in .text("unused") } }
  #expect(chmod(directory, 0o700) == 0)
  let listener = try await WorkerListener.bind(socket: socket) { _ in .text("unused") }
  await #expect(throws: WorkerProtocolError.self) { try await WorkerListener.bind(socket: socket) { _ in .text("unused") } }
  await listener.shutdown()
  let replacement = try await WorkerListener.bind(socket: socket) { _ in .text("unused") }
  await listener.shutdown()
  var state = stat()
  #expect(lstat(socket, &state) == 0)
  await replacement.shutdown()
}

@Test func runCancellationRemovesSocketBeforeRebind() async throws {
  let directory = "/tmp/worker-" + UUID().uuidString
  #expect(mkdir(directory, 0o700) == 0)
  defer { _ = rmdir(directory) }
  let socket = directory + "/owner.sock"
  let listener = try await WorkerListener.bind(socket: socket) { _ in .text("unused") }
  let running = Task { await listener.run() }
  running.cancel()
  await running.value
  let replacement = try await WorkerListener.bind(socket: socket) { _ in .text("unused") }
  await listener.shutdown()
  var state = stat()
  #expect(lstat(socket, &state) == 0)
  await replacement.shutdown()
}

@Test func refusesOpenUploadsWithoutDrainingOverUnix() async throws {
  let directory = "/tmp/worker-" + UUID().uuidString
  #expect(mkdir(directory, 0o700) == 0)
  defer { _ = rmdir(directory) }
  let socket = directory + "/owner.sock"
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { _ in .null }, upload: { _, _ in Issue.record("Unadmitted upload") }, download: { _ in Issue.record("Unadmitted download"); return .empty })
  let listener = try await WorkerListener.bind(socket: socket, handler: endpoint.handler)
  do {
    let direct = FetchClient { try await endpoint.handler($0) }
    let client = try WorkerClient(socket: socket, token: "token", control: direct, bytes: direct)
    _ = try await client.negotiate(.init(release: "worker"))
    let metadata = try JSONEncoder().encode(WorkerCall(operation: "download")).base64EncodedString()
    let cases = [
      ("/worker/upload", "Authorization: Bearer wrong\r\n", "1\r\nx\r\n", "unauthorized"),
      ("/worker/download", "Authorization: Bearer token\r\nX-Wuhu-Worker-Stream: invalid\r\n", "1\r\nx\r\n", "invalidMessage"),
      ("/worker/download", "Authorization: Bearer token\r\nX-Wuhu-Worker-Stream: \(metadata)\r\n", "1\r\nx\r\n", "invalidMessage"),
      ("/worker/call", "Authorization: Bearer token\r\n", "100001\r\n" + String(repeating: "x", count: 0x100001) + "\r\n", "capacityExceeded"),
    ]
    for (path, headers, prefix, code) in cases {
      try await withRawUnix(socket: socket) { channel, recorder in
        let request = "POST \(path) HTTP/1.1\r\nHost: localhost\r\n\(headers)Transfer-Encoding: chunked\r\n\r\n\(prefix)"
        try await channel.writeAndFlush(channel.allocator.buffer(string: request))
        try await waitFor { recorder.inactive }
        #expect(recorder.text.contains("HTTP/1.1 400"))
        #expect(recorder.text.lowercased().contains("connection: close"))
        #expect(recorder.text.contains(code))
      }
    }
  } catch { await listener.shutdown(); throw error }
  await listener.shutdown()
}

@Test func disconnectedReaderCancelsIdleProducerOverUnix() async throws {
  let directory = "/tmp/worker-" + UUID().uuidString
  #expect(mkdir(directory, 0o700) == 0)
  defer { _ = rmdir(directory) }
  let socket = directory + "/owner.sock"
  let terminated = Mutex(false)
  let (stream, continuation) = AsyncStream<Bytes>.makeStream()
  continuation.onTermination = { _ in terminated.withLock { $0 = true } }
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { _ in .null }, upload: { _, body in try await body.discard() }, download: { _ in .stream(stream) })
  let listener = try await WorkerListener.bind(socket: socket, handler: endpoint.handler)
  do {
    let direct = FetchClient { try await endpoint.handler($0) }
    let client = try WorkerClient(socket: socket, token: "token", control: direct, bytes: direct)
    _ = try await client.negotiate(.init(release: "worker"))
    let metadata = try JSONEncoder().encode(WorkerCall(operation: "idle")).base64EncodedString()
    try await withRawUnix(socket: socket) { channel, recorder in
      let request = "POST /worker/download HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer token\r\nX-Wuhu-Worker-Stream: \(metadata)\r\nContent-Length: 0\r\n\r\n"
      try await channel.writeAndFlush(channel.allocator.buffer(string: request))
      try await waitFor { recorder.text.contains("HTTP/1.1 200") }
      try await channel.close()
      try await waitFor { terminated.withLock { $0 } }
    }
  } catch { continuation.finish(); await listener.shutdown(); throw error }
  await listener.shutdown()
}

private final class UnixResponseRecorder: ChannelInboundHandler, Sendable {
  typealias InboundIn = ByteBuffer
  private struct State { var text = ""; var inactive = false }
  private let state = Mutex(State())
  var text: String { state.withLock { $0.text } }
  var inactive: Bool { state.withLock { $0.inactive } }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buffer = unwrapInboundIn(data)
    let text = buffer.readString(length: buffer.readableBytes) ?? ""
    state.withLock { $0.text += text }
    context.fireChannelRead(data)
  }

  func channelInactive(context: ChannelHandlerContext) {
    state.withLock { $0.inactive = true }
    context.fireChannelInactive()
  }
}

private func withRawUnix(socket: String, operation: (Channel, UnixResponseRecorder) async throws -> Void) async throws {
  let recorder = UnixResponseRecorder()
  let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .channelInitializer { $0.pipeline.addHandler(recorder) }
    .connect(unixDomainSocketPath: socket).get()
  do { try await operation(channel, recorder); try? await channel.close() }
  catch { try? await channel.close(); throw error }
}

private enum UnixTestTimeout: Error { case timedOut }
private func waitFor(_ condition: @Sendable () -> Bool) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now + .seconds(3)
  while !condition() {
    guard clock.now < deadline else { throw UnixTestTimeout.timedOut }
    try await clock.sleep(for: .milliseconds(10))
  }
}

@Test func replacesStalePrivateSocketButNeverNonSocketPath() async throws {
  let directory = "/tmp/worker-" + UUID().uuidString
  #expect(mkdir(directory, 0o700) == 0)
  defer { _ = rmdir(directory) }
  let socket = directory + "/owner.sock"
  try createStaleSocket(at: socket)
  var state = stat()
  #expect(lstat(socket, &state) == 0)
  let replacement = try await WorkerListener.bind(socket: socket) { _ in .text("new") }
  await #expect(throws: WorkerProtocolError.self) { try await WorkerListener.bind(socket: socket) { _ in .text("cannot replace live") } }
  await replacement.shutdown()
  let file = open(socket, O_CREAT | O_WRONLY, 0o600)
  #expect(file >= 0)
  if file >= 0 { _ = close(file) }
  await #expect(throws: WorkerProtocolError.self) { try await WorkerListener.bind(socket: socket) { _ in .text("cannot replace file") } }
  #expect(lstat(socket, &state) == 0)
  #expect(state.st_mode & S_IFMT == S_IFREG)
  _ = unlink(socket)
}

private func createStaleSocket(at path: String) throws {
  #if os(Linux)
    let descriptor = Glibc.socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
  #else
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
  #endif
  #expect(descriptor >= 0)
  defer { _ = close(descriptor) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  #if !os(Linux)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
  #endif
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    let bytes = Array(path.utf8) + [0]
    precondition(bytes.count <= buffer.count)
    buffer.copyBytes(from: bytes)
  }
  let result = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
  }
  #expect(result == 0)
  #expect(listen(descriptor, 1) == 0)
  #expect(chmod(path, 0o600) == 0)
}

@Test func slowShutdownPreservesSocketReboundDuringHandlerDrain() async throws {
  let directory = "/tmp/worker-" + UUID().uuidString
  #expect(mkdir(directory, 0o700) == 0)
  defer { _ = rmdir(directory) }
  let socket = directory + "/owner.sock"
  let entered = Mutex(false)
  let stopped = Mutex(false)
  let (release, continuation) = AsyncStream<Void>.makeStream()
  let drain = Task { for await _ in release {} }
  let original = try await WorkerListener.bind(socket: socket) { _ in
    entered.withLock { $0 = true }
    await drain.value
    return .text("old")
  }
  var replacement: WorkerListener?
  do {
    try await withThrowingTaskGroup(of: Void.self) { group in
      defer { continuation.finish() }
      try await withRawUnix(socket: socket) { channel, recorder in
        try await channel.writeAndFlush(channel.allocator.buffer(string: "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
        try await waitFor { entered.withLock { $0 } }
        group.addTask { @Sendable in await original.shutdown(); stopped.withLock { $0 = true } }
        try await waitFor { recorder.inactive }
        #expect(!stopped.withLock { $0 })
        replacement = try await WorkerListener.bind(socket: socket) { _ in .text("new") }
        var rebound = stat()
        #expect(lstat(socket, &rebound) == 0)
        continuation.finish()
        try await group.waitForAll()
        var current = stat()
        #expect(lstat(socket, &current) == 0)
        #expect(current.st_ino == rebound.st_ino)
        #expect(current.st_dev == rebound.st_dev)
        try await withRawUnix(socket: socket) { channel, recorder in
          try await channel.writeAndFlush(channel.allocator.buffer(string: "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"))
          try await waitFor { recorder.inactive }
          #expect(recorder.text.contains("new"))
        }
      }
    }
  } catch {
    continuation.finish()
    await drain.value
    await original.shutdown()
    await replacement?.shutdown()
    throw error
  }
  await drain.value
  await replacement?.shutdown()
}

@Test func finiteDownloadsDeclareLengthAndCompleteAcrossClosingConnections() async throws {
  let directory = "/tmp/worker-" + UUID().uuidString
  #expect(mkdir(directory, 0o700) == 0)
  defer { _ = rmdir(directory) }
  let socket = directory + "/owner.sock"
  let payload = Data(repeating: 42, count: 128 << 10)
  let endpoint = try WorkerEndpoint(token: "token", hello: .init(release: "parent"), invoke: { $0.payload }, upload: { _, body in
    try await body.discard()
  }, download: { call in call.operation == "empty" ? .empty : .bytes(payload) })
  let listener = try await WorkerListener.bind(socket: socket, handler: endpoint.handler)
  let control = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton))
  let bytes = HTTPClient(eventLoopGroupProvider: .shared(MultiThreadedEventLoopGroup.singleton))
  let result: Result<Void, any Error>
  do {
    let actual = FetchClient.asyncHTTPClient(bytes, timeout: .seconds(10))
    let inspecting = FetchClient { request in
      let response = try await actual(request)
      let header = try #require(request.headers[.init("X-Wuhu-Worker-Stream")!])
      let metadata = try #require(Data(base64Encoded: header))
      let call = try JSONDecoder().decode(WorkerCall.self, from: metadata)
      #expect(response.headers[.init("Content-Length")!] == (call.operation == "empty" ? "0" : String(payload.count)))
      #expect(response.headers[.init("Transfer-Encoding")!] == nil)
      return response
    }
    let client = try WorkerClient(socket: socket, token: "token", control: .asyncHTTPClient(control, timeout: .seconds(10)), bytes: inspecting)
    _ = try await client.negotiate(.init(release: "worker"))
    for _ in 0 ..< 30 {
      #expect(try await client.stream(.init(operation: "finite")).data() == payload)
      #expect(try await client.stream(.init(operation: "empty")).data().isEmpty)
      #expect(try await client.call(.init(operation: "control", payload: "alive")) == "alive")
    }
    result = .success(())
  } catch { result = .failure(error) }
  await listener.shutdown()
  try await control.shutdown()
  try await bytes.shutdown()
  try result.get()
}
