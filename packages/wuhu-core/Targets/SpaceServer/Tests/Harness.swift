import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import Foundation
import JSONValue
import MachineChannel
import struct MachineContract.ExecID
import Serve
import ServeTesting
import SessionDomain
import SpaceContract
import struct SpaceContract.GroupID
@testable import SpaceCore
@testable import SpaceServer
import SpaceTools
import Testing

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func testPubkey(_ seed: String) -> String {
  let bytes = Array(seed.utf8.prefix(32))
  return "ed25519:" + Data(bytes + repeatElement(0, count: 32 - bytes.count)).base64EncodedString()
}

struct Harness {
  let space: Space
  let context: SpaceToolContext
  /// The one listener: every host, as the request names it.
  let api: FetchClient
  /// The same listener, with a request to any name off the content host
  /// sent to `shared.<host>`: the content of the shared group.
  let web: FetchClient

  init(
    dev: Bool = true,
    publicRead: Bool = false,
    origin: String? = nil,
    contentHostPattern: String? = nil,
    aiDisclosure: AIDisclosure? = nil,
    fingerprint: String? = nil,
    webApp: WebApp? = nil,
    views: [String: Data] = [:],
    webPushApplicationServerKey: String? = nil,
    credentials: CredentialResolver = .unavailable,
    pageFetch: PageFetchHandler? = nil,
    identityJWKS: JSONValue? = nil,
    opening: () throws -> Space = { try Space.inMemory() },
  ) throws {
    let contentHost = ContentHost(origin: origin ?? "https://localhost", pattern: contentHostPattern)!
    let (space, handler) = try withDependencies {
      $0.date = .constant(fixedDate)
      $0.continuousClock = ContinuousClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 11))
    } operation: {
      let space = try opening()
      let hub = MachineHub(space: space)
      let handler = SpaceServer.configuredHandler(
        space: space, hub: hub, origin: origin, contentHostPattern: contentHostPattern, aiDisclosure: aiDisclosure,
        fingerprint: fingerprint, dev: dev, publicRead: publicRead, webContent: WebContent(webApp: webApp, views: views, scripts: ["shell.js": Data(), "worker.js": Data(), "space-core.js": Data("export function createSpace() {}".utf8)]),
        webPushApplicationServerKey: webPushApplicationServerKey,
        credentials: credentials, identityJWKS: identityJWKS, pageFetch: pageFetch,
      )
      return (space, handler)
    }
    self.space = space
    self.context = SpaceToolContext(space: space, principal: .shared(.anonymous))
    self.api = ServeTesting.client(upgrading: handler)
    self.web = ServeTesting.client(upgrading: { request in
      guard contentHost.plane(of: request.url.host) == .api,
            var components = URLComponents(url: request.url, resolvingAgainstBaseURL: false)
      else { return try await handler(request) }
      components.host = "shared." + contentHost.host
      var shared = request
      shared.url = components.url!
      return try await handler(shared)
    })
  }

  func post(_ tool: String, _ input: JSONValue) async throws -> Response {
    try await api(Request(
      url: URL(string: "http://space/v1/tools/\(tool)")!,
      method: .post,
      body: .bytes(Data(input.jsonString().utf8), contentType: "application/json"),
    ))
  }

  func call<Output: Decodable>(_ tool: String, _ input: JSONValue, as output: Output.Type) async throws -> Output {
    let response = try await post(tool, input)
    #expect(response.status == .ok)
    return try JSONValueDecoder().decode(output, from: try await json(response))
  }

  func direct(_ name: String, _ input: JSONValue) async throws -> JSONValue {
    try await SpaceToolbox.all.first { $0.name == name }!.run(context, input: input)
  }

  func get(_ client: FetchClient, _ path: String, query: [String: String] = [:]) async throws -> Response {
    var components = URLComponents(string: "http://space")!
    components.path = path
    if !query.isEmpty {
      components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
    }
    return try await client(Request(url: components.url!))
  }
}

func json(_ response: Response) async throws -> JSONValue {
  let text = try await response.text()
  return try #require(JSONValue.parse(text))
}

// An exec's in-process caller leg: what the WebSocket route hands a dialing client.
func connectExecCaller(_ id: ExecID, space: Space, hub: MachineHub) async throws -> any FrameTransport {
  guard let record = try await space.execRecord(id) else { throw MachineHubError.execNotFound(id) }
  let (server, client) = WebSocket.pair()
  _ = try? hub.callerScope.run("in-process-exec-caller") {
    await hub.runCallerSession(record, socket: server, leg: record.caller.map { .session(SessionID(rawValue: $0)) } ?? .anonymous)
  }
  return WebSocketTransport(client)
}
