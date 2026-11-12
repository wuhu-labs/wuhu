import Crypto
import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import MachineContract
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.deterministicDependencies) struct IDTokenRouteTests {
  struct Rig {
    let harness: SessionHarness
    let tokens: ExecTokens
    let key: ServerIdentity
    let session: SessionID
    let machine: MachineID
    let exec: ExecID
    let request: String
  }

  func rig(dev: Bool = true, identity: Bool = true) async throws -> Rig {
    let key = try await ServerIdentity.loadOrCreate(from: MemoryFiles().keyStore("/identity.p256"))
    let controller = IdentityController.configure(space: try Space.inMemory(), origin: "https://space.test", keys: MemoryFiles().identityKeys, fetch: FetchClient { _ in Response(status: .forbidden) })
    try await controller.initialize(identity: key)
    let harness = try await SessionHarness(dev: dev, origin: "https://space.test", spaceURL: "https://space.test", identityController: identity ? controller : nil)
    let tokens = harness.runtime.tokens
    let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
    let session = try await harness.store.createSession(group: .shared, title: "coder", kind: .agent, createdBy: "owner", executor: model)
    let machine = (try await harness.space.addMachineV2(name: "box")).machine
    let exec = try await harness.space.reserveExec(machine: machine.id, caller: session.rawValue)
    let token = try await tokens.credential(session: session, exec: exec.id, timeout: 600, now: Date()).token
    return Rig(harness: harness, tokens: tokens, key: key, session: session, machine: machine.id, exec: exec.id, request: token)
  }

  @Test func aRunningExecMintsASixtySecondTokenNamingItsSessionMachineAndExec() async throws {
    try await withSessionDeps {
      let r = try await rig()
      let response = try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: r.request)
      #expect(response.status == .ok)
      #expect(response.headers[.cacheControl] == "no-store")
      let body = try #require(JSONValue.parse(try await response.text())?.object)
      let token = try #require(body["token"]?.stringValue)
      let claims = try jwtClaims(token)
      let space = try await r.harness.space.identity().rawValue
      #expect(claims["iss"] == "https://space.test")
      #expect(claims["aud"] == "https://pool.example")
      #expect(claims["space"] == .string(space))
      #expect(claims["group"] == "shared")
      #expect(claims["sub"] == .string("shared/" + r.session.rawValue))
      #expect(claims["session"] == .string(r.session.rawValue))
      #expect(claims["machine"] == .string(r.machine.rawValue))
      #expect(claims["exec"] == .string(r.exec.rawValue))
      let issued = try #require(claims["iat"]?.intValue)
      #expect(claims["exp"]?.intValue == issued + 60)
      #expect(body["expiresAt"]?.intValue == issued + 60)
      try jwtVerify(token, jwks: r.key.jwks)
    }
  }

  @Test func onlyASignedSessionCredentialAuthenticatesIt() async throws {
    try await withSessionDeps {
      let r = try await rig()
      let execToken = try await r.tokens.credential(session: r.session, exec: r.exec, timeout: 600, now: Date()).token
      for bearer in [nil, "wit_" + String(repeating: "0", count: 64)] {
        let response = try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: bearer)
        #expect(response.status == .unauthorized, "\(bearer ?? "none")")
      }
      #expect(try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: execToken).status == .ok)
      let sessionToken = try await r.tokens.sessionToken(r.session)
      let sessionReply = try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: sessionToken).json(JSONValue.self)
      let sessionClaims = try jwtClaims(#require(sessionReply.object?["token"]?.stringValue))
      #expect(sessionClaims["session"] == .string(r.session.rawValue))
      #expect(sessionClaims["machine"] == nil && sessionClaims["exec"] == nil)
    }
  }

  @Test func theAudienceMustBeAnOrigin() async throws {
    try await withSessionDeps {
      let r = try await rig()
      for audience in ["https://pool.example/v1", "HTTPS://pool.example", "ftp://pool.example", "pool.example", "https://pool.example:443"] {
        let response = try await r.harness.get("/v1/id-token", query: ["audience": audience], bearer: r.request)
        #expect(response.status == .badRequest, "\(audience)")
      }
      #expect(try await r.harness.get("/v1/id-token", bearer: r.request).status == .badRequest)
      #expect(try await r.harness.get("/v1/id-token", query: ["audience": "http://10.0.16.215:5588"], bearer: r.request).status == .ok)
    }
  }

  @Test func itEndsWithTheExecAndRefusesAnArchivedSession() async throws {
    try await withSessionDeps {
      let r = try await rig()
      try await setExecTerminalFixture(space: r.harness.space, exec: r.exec, terminal: .exited(code: 0))
      let ended = try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: r.request)
      #expect(ended.status == .unauthorized)
      #expect(try await ended.text().contains("ended"))

      let other = try await rig()
      _ = try await other.harness.store.archive(other.session, grace: .seconds(3600))
      let archived = try await other.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: other.request)
      #expect(archived.status == .forbidden)
      #expect(try await archived.text().contains("is archived"))
    }
  }

  @Test func machineLossEndsIt() async throws {
    try await withSessionDeps {
      let r = try await rig()
      try await setExecTerminalFixture(space: r.harness.space, exec: r.exec, terminal: .machineLost)
      let lost = try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: r.request)
      #expect(lost.status == .unauthorized)
    }
  }

  @Test func itPrecedesTheWallOfANonDevServer() async throws {
    try await withSessionDeps {
      let r = try await rig(dev: false)
      #expect(try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: r.request).status == .ok)
      #expect(try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"]).status == .unauthorized)
    }
  }

  @Test func withoutAServerIdentityItIsUnavailable() async throws {
    try await withSessionDeps {
      let r = try await rig(identity: false)
      #expect(try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: r.request).status == .serviceUnavailable)
    }
  }
}

private func jwtClaims(_ token: String) throws -> [String: JSONValue] {
  let object = try #require(JSONValue.parse(String(decoding: jwtPart(String(token.split(separator: ".")[1])), as: UTF8.self))?.object)
  return Dictionary(uniqueKeysWithValues: object.map { ($0.key, $0.value) })
}

private func jwtPart(_ value: String) throws -> Data {
  let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  return try #require(Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)))
}

private func jwtVerify(_ token: String, jwks: JSONValue) throws {
  let parts = token.split(separator: ".").map(String.init)
  let jwk = try #require(jwks.object?["keys"]?.array?.first?.object)
  let point = Data([4]) + (try jwtPart(#require(jwk["x"]?.stringValue))) + (try jwtPart(#require(jwk["y"]?.stringValue)))
  let key = try P256.Signing.PublicKey(x963Representation: point)
  #expect(try key.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: jwtPart(parts[2])), for: Data((parts[0] + "." + parts[1]).utf8)))
}
