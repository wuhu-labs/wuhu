import NIOCore
import NIOPosix
@testable import ServeNIO
import Synchronization
import Testing

@Suite struct ShutdownHookTests {
  @Test(arguments: [false, true]) func completionIsPublishedAfterDidShutdownHook(cancelRunner: Bool) async throws {
    let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
    let state = ServeNIOServerState()
    let hookCalls = Mutex(0)
    let server = ServeNIOServer(
      serverChannel: channel,
      boundAddress: try #require(channel.localAddress),
      hooks: .init(onDidShutdown: { _ in
        guard case .inProgress = state.beginShutdown() else {
          Issue.record("shutdown completion was published before onDidShutdown returned")
          return
        }
        hookCalls.withLock { $0 += 1 }
      }),
      state: state,
    )
    let waiting = Task { @Sendable in
      await server.waitUntilShutdown()
      #expect(hookCalls.withLock { $0 } == 1)
    }
    let running = Task { @Sendable in
      await server.runUntilCancelled()
      #expect(hookCalls.withLock { $0 } == 1)
    }
    if cancelRunner { running.cancel() }
    else { await server.shutdown() }
    await running.value
    await waiting.value
    await server.shutdown()
    #expect(hookCalls.withLock { $0 } == 1)
    guard case .finished = state.beginShutdown() else {
      Issue.record("shutdown completion was not published")
      return
    }
  }
}
