@testable import ExecSupervisor
import class NIOPosix.MultiThreadedEventLoopGroup
import Testing

@Suite struct UnixHTTPTests {
  @Test func privateUnixTransportUsesPOSIXOnEveryPlatformAndClosesOnSuccess() async throws {
    let value = try await withUnixHTTP { client, group in
      #expect(client.eventLoopGroup is MultiThreadedEventLoopGroup && client.eventLoopGroup === group)
      return 42
    }
    #expect(value == 42)
  }

  @Test func privateUnixTransportClosesAndPreservesBodyFailure() async throws {
    enum Failure: Error { case injected }
    do {
      let _: Int = try await withUnixHTTP { client, group in
        #expect(client.eventLoopGroup is MultiThreadedEventLoopGroup && client.eventLoopGroup === group)
        throw Failure.injected
      }
      Issue.record("expected failure")
    } catch Failure.injected {}
  }
}
