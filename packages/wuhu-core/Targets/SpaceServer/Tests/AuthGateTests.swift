import AsyncHTTPClient
import Dependencies
import Fetch
import FetchAsyncHTTPClient
import Foundation
import JSONValue
import ServeNIO
import SpaceServer
import Testing

// The auth gate's 401 leaves the request body unread; the substrate must
// still deliver the crafted JSON response over a real socket instead of a
// bare 500.
@Suite struct AuthGateTests {
  @Test func nonDevPostWithABodyGetsTheCrafted401OverARealSocket() async throws {
    let space = try makeMachineSpace()
    let hub = withDependencies {
      $0.continuousClock = ContinuousClock()
    } operation: {
      MachineHub(space: space)
    }
    let server = try await ServeNIOServer.bind(
      port: 0,
      upgrading: SpaceServer.handler(space: space, hub: hub, dev: false),
    )
    do {
      let port = try #require(server.localAddress?.port)
      let client = HTTPClient(eventLoopGroupProvider: .singleton)
      do {
        let request = Request(
          url: try #require(URL(string: "http://127.0.0.1:\(port)/v1/machine")),
          method: .post,
          body: .bytes(Data(#"{"name":"box"}"#.utf8), contentType: "application/json"),
        )
        let response = try await FetchClient.asyncHTTPClient(client)(request)
        #expect(response.status == .unauthorized)
        let payload = JSONValue.parse(try await response.text())
        guard case let .object(fields)? = payload else {
          throw UnexpectedResponse(status: response.status)
        }
        #expect(fields["code"] == .string("unauthorized"))
        try await client.shutdown()
      } catch {
        try? await client.shutdown()
        throw error
      }
      await server.shutdown()
    } catch {
      await server.shutdown()
      throw error
    }
  }
}
