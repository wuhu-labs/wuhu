import struct Credentials.SpaceSecrets
import struct Credentials.SpaceSecretStores
import Fetch
import Foundation
import JSONValue
import Scratch
import Serve
import ServeTesting
import SpaceContract
import SpaceCore
import SpaceServer
import Testing

@Suite struct SecretRoutesTests {
  @Test func setListAndRemoveNeverReturnAValue() async throws {
    try await withSecretsClient { client, store in
      #expect(try await client(.put, "/v1/secret/GITHUB_TOKEN", ["value": "ghp_first"]).status == .ok)
      #expect(try await client(.put, "/v1/secret/GITHUB_TOKEN", ["value": "ghp_second"]).status == .ok)
      #expect(try await client(.put, "/v1/secret/OTHER", ["value": "x"]).status == .ok)
      #expect(try await store.value(of: "GITHUB_TOKEN") == "ghp_second")

      let listed = try await client(.get, "/v1/secret", nil)
      let text = try await listed.text()
      #expect(!text.contains("ghp_"))
      #expect(try JSONDecoder().decode(SecretsOutput.self, from: Data(text.utf8)).names == ["GITHUB_TOKEN", "OTHER"])

      #expect(try await client(.delete, "/v1/secret/OTHER", nil).status == .ok)
      #expect(try await store.names() == ["GITHUB_TOKEN"])
    }
  }

  @Test func refusalsMapToStatuses() async throws {
    try await withSecretsClient { client, _ async throws in
      #expect(try await client(.put, "/v1/secret/not-a-name", ["value": "x"]).status == .badRequest)
      #expect(try await client(.put, "/v1/secret/EMPTY", ["value": ""]).status == .badRequest)
      #expect(try await client(.put, "/v1/secret/NO_BODY", ["wrong": "x"]).status == .badRequest)
      #expect(try await client(.delete, "/v1/secret/MISSING", nil).status == .notFound)
    }
    try await withSessionDeps {
      let space = try Space.inMemory()
      let api = ServeTesting.client(upgrading: SpaceServer.handler(space: space, hub: MachineHub(space: space), dev: true, webApp: nil))
      #expect(try await api(Request(url: URL(string: "http://space/v1/secret")!)).status == .serviceUnavailable)
    }
  }
}

private typealias SecretsClient = (Fetch.Method, String, JSONValue?) async throws -> Response

private func withSecretsClient(_ body: (SecretsClient, SpaceSecrets) async throws -> Void) async throws {
  let folder = try scratchURL("secret-routes")
  defer { try? FileManager.default.removeItem(at: folder) }
  let stores = SpaceSecretStores(configDirectory: folder, spaceID: "spc_test")
  let store = try stores.group("shared")
  try await withSessionDeps {
    let space = try Space.inMemory()
    let api = ServeTesting.client(upgrading: SpaceServer.handler(
      space: space, hub: MachineHub(space: space), dev: true, webApp: nil, secrets: stores,
    ))
    try await body({ method, path, json in
      var request = Request(url: URL(string: "http://space\(path)")!, method: method)
      if let json {
        request.body = .bytes(Data(json.jsonString().utf8), contentType: "application/json")
      }
      return try await api(request)
    }, store)
  }
}
