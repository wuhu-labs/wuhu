#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

@testable import CLIKit
import Clocks
import Dependencies
import Fetch
import JSONValue
import protocol MachineChannel.FrameTransport
import struct MachineContract.ExecID
import struct MachineContract.ExecStart
import struct MachineContract.ExecStatus
import struct MachineContract.MachineID
import Scratch
import Serve
import ServeNIO
import struct SpaceClient.ExecSession
import struct SpaceClient.SpaceClient
import Testing

// A dial the server answers with an HTTP error is its answer, not a dead
// network: the exec ends naming the status and message instead of redialing
// until it calls the server unreachable.
@Suite struct ExecDialRefusalTests {
  static let refusalBody = Array(#"{"code":"forbidden","message":"not available to a session"}"#.utf8)

  @Test func theDialerSurfacesAnHTTPRefusalWithItsStatusAndMessage() async throws {
    let directory = try scratchURL("dial-refusal")
    defer { try? FileManager.default.removeItem(at: directory) }
    let server = try await ServeNIOServer.bind(host: "127.0.0.1", port: 0, upgrading: { _ in
      var headers = Headers()
      headers[.contentType] = "application/json"
      return .response(Response(status: .forbidden, headers: headers, body: .bytes(Data(Self.refusalBody))))
    })
    do {
      let port = try #require(server.boundAddress.port)
      let dial = SpaceTransport.webSocketTransport(trust: ServerTrust(directory: directory), maxFrameBytes: 1 << 20)
      await #expect(throws: SpaceClient.DialRefusal(status: 403, body: Self.refusalBody)) {
        _ = try await dial(URL(string: "ws://127.0.0.1:\(port)/v1/exec/ex_abcdefgh")!, [])
      }
      await server.shutdown()
    } catch {
      await server.shutdown()
      throw error
    }
  }

  @Test func aRefusedDialEndsTheExecNamingTheRefusal() async throws {
    let dials = DialCounter { SpaceClient.DialRefusal(status: 403, body: Self.refusalBody) }
    let termination = try await run(dials)
    #expect(termination == .streamFailed("403 forbidden: not available to a session"))
    #expect(await dials.count == 1)
  }

  @Test func networkErrorsAndServerErrorsStillRedialUntilUnreachable() async throws {
    struct Unreachable: Error {}
    let network = DialCounter { Unreachable() }
    #expect(try await run(network) == .unreachable(attempts: 8))
    #expect(await network.count == 8)

    let gateway = DialCounter { SpaceClient.DialRefusal(status: 502, body: Array("bad gateway".utf8)) }
    #expect(try await run(gateway) == .unreachable(attempts: 8))
  }

  private func run(_ dials: DialCounter) async throws -> ExecSession.Termination {
    let id = ExecID(rawValue: "ex_abcdefgh")
    let status = ExecStatus(id: id, machine: MachineID(rawValue: "mc_abcdefgh"), command: "true", startedAt: 0, state: .live)
    let client = SpaceClient(
      space: "127.0.0.1:5530",
      fetch: FetchClient { _ in try Response.json(status) },
      dial: { _, _ in try await dials.dial() },
    )
    let start = ExecStart(id: id, cwd: "/", command: ["true"], env: nil, secrets: nil, window: nil, maxOutput: nil, timeout: nil)
    return try await withDependencies {
      $0.continuousClock = ImmediateClock()
    } operation: {
      try await ExecSession(client: client, start: start).run(input: nil) { _, _ in }
    }
  }
}

private actor DialCounter {
  let failure: @Sendable () -> any Error
  var count = 0

  init(_ failure: @escaping @Sendable () -> any Error) {
    self.failure = failure
  }

  func dial() throws -> any FrameTransport {
    self.count += 1
    throw self.failure()
  }
}
