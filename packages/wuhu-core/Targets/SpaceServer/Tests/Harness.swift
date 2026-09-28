import struct Credentials.CredentialResolver
import Dependencies
import Fetch
import Foundation
import JSONValue
import Serve
import ServeTesting
import SpaceContract
import SpaceCore
@testable import SpaceServer
import SpaceTools
import Testing

let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

func testPubkey(_ seed: String) -> String {
  let bytes = Array(seed.utf8.prefix(32))
  return "ed25519:" + Data(bytes + repeatElement(0, count: 32 - bytes.count)).base64EncodedString()
}

struct Harness {
  static let apiPort = 4100

  let space: Space
  let context: SpaceToolContext
  let api: FetchClient
  let web: FetchClient

  init(
    dev: Bool = true,
    publicRead: Bool = false,
    origin: String? = nil,
    webPort: Int? = nil,
    webOrigin: String? = nil,
    fingerprint: String? = nil,
    webApp: WebApp? = nil,
    views: ViewProviders? = nil,
    webPushApplicationServerKey: String? = nil,
    credentials: CredentialResolver = .unavailable,
    opening: () throws -> Space = { try Space.inMemory() },
  ) throws {
    let (space, handler, webHandler) = try withDependencies {
      $0.date = .constant(fixedDate)
      $0.continuousClock = ContinuousClock()
      $0.withRandomNumberGenerator = WithRandomNumberGenerator(SeededRNG(seed: 11))
    } operation: {
      let space = try opening()
      let hub = MachineHub(space: space)
      let handler = SpaceServer.configuredHandler(
        space: space, hub: hub, origin: origin, webPort: webPort, webOrigin: webOrigin,
        fingerprint: fingerprint, dev: dev, webApp: webApp,
        webPushApplicationServerKey: webPushApplicationServerKey,
        credentials: credentials,
      )
      let webHandler = SpaceServer.webHandler(
        space: space,
        apiPort: Self.apiPort,
        advertisedOrigin: origin,
        webOrigin: webOrigin,
        dev: dev,
        publicRead: publicRead,
        views: views,
      )
      return (space, handler, webHandler)
    }
    self.space = space
    self.context = SpaceToolContext(space: space, principal: .shared(.anonymous))
    self.api = ServeTesting.client(upgrading: handler)
    self.web = ServeTesting.client(webHandler)
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
