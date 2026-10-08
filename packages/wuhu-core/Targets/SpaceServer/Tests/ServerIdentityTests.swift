import Crypto
import Dependencies
import Fetch
import Foundation
import JSONValue
import Scratch
import ServeTesting
@testable import SpaceServer
import Testing
import enum WuhuAI.InferenceError
import WuhuVFS

@Suite struct ServerIdentityTests {
  @Test func jwksVerifiesTokenAndKeySurvivesReopen() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let first = try await ServerIdentity.loadOrCreate(from: fs)
    let reopened = try await ServerIdentity.loadOrCreate(from: fs)
    #expect(first.jwks == reopened.jwks)
    let jwt = try reopened.token(issuer: "https://tenant.wuhu.space", audience: URL(string: "http://172.31.255.1:8089/v1?ignored=true")!, space: "space-id", group: "main", session: "blue-fox-tree", now: fixedDate, id: UUID(0))
    #expect(jwt.utf8.count < 1024)
    let parts = jwt.split(separator: ".").map(String.init)
    let claims = try #require(JSONValue.parse(String(decoding: decode(parts[1]), as: UTF8.self))?.object)
    #expect(claims["iss"] == .string("https://tenant.wuhu.space"))
    #expect(claims["aud"] == .string("http://172.31.255.1:8089"))
    #expect(claims["space"] == .string("space-id"))
    #expect(claims["sub"] == .string("main/blue-fox-tree"))
    #expect(claims["group"] == .string("main"))
    #expect(claims["session"] == .string("blue-fox-tree"))
    #expect(claims["iat"] == .integer(1_700_000_000))
    #expect(claims["exp"] == .integer(1_700_000_300))
    #expect(claims["jti"] == .string(UUID(0).uuidString.lowercased()))
    let jwk = try #require(first.jwks.object?["keys"]?.array?.first?.object)
    #expect(jwk["kid"] == .string(first.kid))
    #expect(jwk["d"] == nil)
    let point = Data([4]) + (try decode(#require(jwk["x"]?.stringValue))) + (try decode(#require(jwk["y"]?.stringValue)))
    let key = try P256.Signing.PublicKey(x963Representation: point)
    #expect(try key.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2])), for: Data((parts[0] + "." + parts[1]).utf8)))
    let groupJWT = try first.token(issuer: "https://tenant.wuhu.space", audience: URL(string: "custom://service/route")!, space: "space-id", group: "main", now: fixedDate, id: UUID(1))
    let groupClaims = try #require(JSONValue.parse(String(decoding: decode(String(groupJWT.split(separator: ".")[1])), as: UTF8.self))?.object)
    #expect(groupClaims["sub"] == .string("main"))
    #expect(groupClaims["session"] == nil)
    #expect(groupClaims["aud"] == .string("custom://service"))
  }

  @Test func inferenceSigningConfigurationErrorsNameTheCorrectKnob() throws {
    let identity = try ServerIdentity(rawKey: P256.Signing.PrivateKey().rawRepresentation)
    #expect(throws: InferenceError.invalidInput(status: 422, body: "OIDC token audience is invalid; check the provider baseURL.")) {
      try identity.tokenForInference(issuer: "https://origin.example.test", audience: URL(string: "http://user:private-secret@172.31.255.1:8089")!, space: "space", group: "main", session: "s", now: fixedDate, id: UUID(0))
    }
    #expect(throws: InferenceError.invalidInput(status: 422, body: "OIDC token issuer is invalid; check HTTPS --origin.")) {
      try identity.tokenForInference(issuer: nil, audience: URL(string: "http://172.31.255.1:8089")!, space: "space", group: "main", session: "s", now: fixedDate, id: UUID(0))
    }
  }

  @Test func inferenceKeyErrorsHaveStaticActionable422Hints() {
    #expect(IdentityError.keyUnavailable.inferenceError == .invalidInput(status: 422, body: "OIDC identity key is unavailable; check the server identity key configuration."))
    #expect(IdentityError.signingFailed.inferenceError == .invalidInput(status: 422, body: "OIDC token signing failed; check the server identity key configuration."))
  }

  @Test func diskKeySurvivesRestartWithPrivatePermissions() async throws {
    let scratch = try scratchURL("server-identity")
    defer { try? FileManager.default.removeItem(at: scratch) }
    let directory = scratch.appendingPathComponent("identity")
    let first = try await ServerIdentity.loadOrCreate(directory: directory)
    let second = try await ServerIdentity.loadOrCreate(directory: directory)
    #expect(first.jwks == second.jwks)
    let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("identity.p256").path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
  }

  @Test func corruptStoredKeyIsNotReplaced() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let path = try VFSPath(absoluteFilePath: "/identity.p256")
    try await fs.createFile(at: path, data: Data("bad key".utf8))
    await #expect(throws: (any Error).self) { try await ServerIdentity.loadOrCreate(from: fs) }
    #expect(try await fs.readData(at: path) == Data("bad key".utf8))
  }

  @Test(arguments: ["https://origin.example.test", "https://acme.wuhu.space"])
  func discoveryIsUnauthenticatedAndUsesConfiguredIssuer(origin: String) async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let identity = try await ServerIdentity.loadOrCreate(from: fs)
    let space = try makeMachineSpace()
    let handler = withDependencies { $0.continuousClock = ContinuousClock() } operation: {
      SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), origin: origin, dev: false, webApp: nil, identityJWKS: identity.jwks)
    }
    let client = ServeTesting.client(upgrading: handler)
    let discovery = try await client(Request(url: URL(string: origin + "/.well-known/openid-configuration")!))
    #expect(discovery.status == .ok)
    let config = try await json(discovery)
    #expect(config.object?["issuer"] == .string(origin))
    #expect(config.object?["jwks_uri"] == .string(origin + "/.well-known/jwks.json"))
    let keys = try await client(Request(url: URL(string: origin + "/.well-known/jwks.json")!))
    #expect(keys.status == .ok)
    #expect(try await json(keys) == identity.jwks)
  }

  @Test(arguments: ["http://space.test", "https://user:password@space.test", "https://space.test/path", "https://space.test?query=1"])
  func invalidIssuerIsRejected(origin: String) throws {
    #expect(throws: IdentityError.invalidIssuer) { try ServerIdentity.issuer(origin) }
  }

  @Test func audienceIsCanonicalAndRejectsUserInformation() async throws {
    let identity = try await ServerIdentity.loadOrCreate(from: NodeTreeVFS(root: InMemoryVFSNode()))
    let token = try identity.token(issuer: "https://space.test", audience: URL(string: "https://PROVIDER.test:443/v1")!, space: "s", group: "g", now: fixedDate, id: UUID(0))
    let claims = try #require(JSONValue.parse(String(decoding: decode(String(token.split(separator: ".")[1])), as: UTF8.self))?.object)
    #expect(claims["aud"] == .string("https://provider.test"))
    #expect(throws: IdentityError.invalidAudience) {
      try identity.token(issuer: "https://space.test", audience: URL(string: "http://secret@provider.test")!, space: "s", group: "g", now: fixedDate, id: UUID(0))
    }
  }

  @Test func noOriginNeverUsesRequestHost() async throws {
    let harness = try Harness(dev: false)
    for path in ["/.well-known/openid-configuration", "/.well-known/jwks.json"] {
      let response = try await harness.api(Request(url: URL(string: "https://attacker.test" + path)!))
      #expect(response.status == .unprocessableContent)
      #expect(try await json(response).object?["code"] == .string("oidcConfiguration"))
    }
    let identity = try await ServerIdentity.loadOrCreate(from: NodeTreeVFS(root: InMemoryVFSNode()))
    #expect(throws: IdentityError.invalidIssuer) {
      try identity.token(issuer: nil, audience: URL(string: "https://provider.test")!, space: "s", group: "g", now: fixedDate, id: UUID(0))
    }
  }
}

private func decode(_ value: String) throws -> Data {
  let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  return try #require(Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)))
}
