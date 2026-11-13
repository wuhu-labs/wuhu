#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import NIOCore
import NIOPosix
import Serve
import ServeNIO
import Synchronization
import Testing

/// Two servers on one port, as the outgoing and the incoming process of a
/// release: the second binds while the first still serves, and the port keeps
/// answering once the first stops accepting. Which of the two receives a
/// connection is the kernel's business — Linux hashes, Darwin serves from the
/// most recent listener — so the test asserts the port, not the split.
@Suite(.serialized)
struct RolloverShutdownTests {
  @Test func twoServersShareOnePort() async throws {
    let first = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0) { _ in
      Response(status: .ok, body: .chunk(Data("first".utf8)))
    }

    do {
      let port = try #require(first.boundAddress.port)
      let second = try await ServeNIOServer.bind(host: "127.0.0.1", port: port) { _ in
        Response(status: .ok, body: .chunk(Data("second".utf8)))
      }

      do {
        let shared = try await sendRawHTTP(port: port, request: "GET / HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n")
        #expect(shared.contains("first") || shared.contains("second"))
        await first.stopAccepting()
        let survivor = try await sendRawHTTP(port: port, request: "GET / HTTP/1.1\r\nHost: local\r\nConnection: close\r\n\r\n")
        #expect(survivor.contains("second"))
      } catch {
        await second.shutdown()
        throw error
      }
      await second.shutdown()
    } catch {
      await first.shutdown()
      throw error
    }

    await first.shutdown()
  }
}

private enum RolloverTimeout: Error {
  case timedOut
}

private func bounded<T: Sendable>(
  seconds: Double,
  _ operation: @escaping @Sendable () async -> T,
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw RolloverTimeout.timedOut
    }
    let value = try await group.next()
    group.cancelAll()
    return try #require(value)
  }
}

private final class RawResponse: ChannelInboundHandler, Sendable {
  typealias InboundIn = ByteBuffer

  private let text = Mutex("")
  private let finished = Mutex(false)

  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    var buffer = self.unwrapInboundIn(data)
    let chunk = buffer.readString(length: buffer.readableBytes) ?? ""
    self.text.withLock { $0 += chunk }
    context.fireChannelRead(data)
  }

  func channelInactive(context: ChannelHandlerContext) {
    self.finished.withLock { $0 = true }
    context.fireChannelInactive()
  }

  var body: String {
    self.text.withLock { $0 }
  }

  var isFinished: Bool {
    self.finished.withLock { $0 }
  }
}

private func sendRawHTTP(port: Int, request: String) async throws -> String {
  let responses = RawResponse()
  let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
    .channelInitializer { channel in
      channel.pipeline.addHandler(responses)
    }
    .connect(host: "127.0.0.1", port: port)
    .get()
  do {
    try await channel.writeAndFlush(channel.allocator.buffer(string: request))
    try await bounded(seconds: 5) {
      while !responses.isFinished {
        try? await Task.sleep(nanoseconds: 10_000_000)
      }
    }
    try? await channel.close()
    return responses.body
  } catch {
    try? await channel.close()
    throw error
  }
}
