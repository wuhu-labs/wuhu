import Crypto
import Fetch
import Foundation
import JSONValue
import MachineContract
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Testing
import WuhuVFS

// A session's exec trades its WUHU_ID_TOKEN_REQUEST capability for a short
// OIDC token naming its session, machine and exec, through the real handler.
@Suite struct IDTokenRouteTests {
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
    let tokens = ExecTokens(spaceURL: "https://space.test")
    let key = try await ServerIdentity.loadOrCreate(from: NodeTreeVFS(root: InMemoryVFSNode()))
    let controller = try IdentityController(
      identity: key, origin: "https://space.test", store: .filesystem(NodeTreeVFS(root: InMemoryVFSNode())),
      fetch: FetchClient { _ in Response(status: .forbidden) },
    )
    let harness = try await SessionHarness(dev: dev, origin: "https://space.test", execTokens: tokens, identityController: identity ? controller : nil)
    let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
    let session = try await harness.store.createSession(group: .shared, title: "coder", kind: .agent, createdBy: "owner", executor: model)
    let machine = try await harness.space.addMachine(name: "box")
    let exec = try await harness.space.mintExec(machine: machine.id, caller: session.rawValue)
    let minting = tokens.idTokens.environment(spaceURL: tokens.spaceURL, session: session, machine: machine.id, exec: exec.id, timeout: 600, now: Date())
    #expect(minting.url == "https://space.test/v1/id-token")
    return Rig(harness: harness, tokens: tokens, key: key, session: session, machine: machine.id, exec: exec.id, request: minting.request)
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

  @Test func onlyTheCapabilityAuthenticatesIt() async throws {
    try await withSessionDeps {
      let r = try await rig()
      let execToken = r.tokens.credential(session: r.session, exec: r.exec, timeout: 600, now: Date()).token
      for bearer in [nil, IDTokenGrants.prefix + String(repeating: "0", count: 64)] {
        let response = try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: bearer)
        #expect(response.status == .unauthorized, "\(bearer ?? "none")")
      }
      // The session gate takes the exec token and refuses the route to sessions.
      #expect(try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: execToken).status == .forbidden)
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
      try await r.harness.space.finishExec(r.exec, .exited(code: 0))
      let ended = try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: r.request)
      #expect(ended.status == .unauthorized)
      #expect(try await ended.text().contains("has ended"))
      #expect(r.tokens.idTokens.grant(ofBearer: r.request, now: Date()) == nil)

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
      try await r.harness.space.finishExec(r.exec, .machineLost)
      let lost = try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: r.request)
      #expect(lost.status == .unauthorized)
      #expect(r.tokens.idTokens.expiry(of: r.exec) == nil)
    }
  }

  @Test func revokingTheExecsTokensRevokesTheCapability() async throws {
    try await withSessionDeps {
      let r = try await rig()
      r.tokens.revoke(r.exec)
      #expect(try await r.harness.get("/v1/id-token", query: ["audience": "https://pool.example"], bearer: r.request).status == .unauthorized)
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

  @Test func aGrantLivesForTheExecsTimeoutCappedAtADayAndIsStablePerExec() {
    let grants = IDTokenGrants()
    let now = Date()
    let session = SessionID("s"), machine = MachineID(rawValue: "mc_a"), exec = ExecID(rawValue: "ex_aaaaaaaa")
    let short = grants.environment(spaceURL: "https://space.test", session: session, machine: machine, exec: exec, timeout: 60, now: now)
    #expect(short.request.hasPrefix(IDTokenGrants.prefix) && short.request.count == 68)
    #expect(grants.environment(spaceURL: "https://space.test", session: session, machine: machine, exec: exec, timeout: 60, now: now).request == short.request)
    #expect(grants.grant(ofBearer: short.request, now: now.addingTimeInterval(59)) == .init(session: session, machine: machine, exec: exec, expiresAt: now.addingTimeInterval(60)))
    #expect(grants.grant(ofBearer: short.request, now: now.addingTimeInterval(61)) == nil)
    let long = grants.environment(spaceURL: "https://space.test", session: session, machine: machine, exec: ExecID(rawValue: "ex_bbbbbbbb"), timeout: nil, now: now)
    #expect(grants.grant(ofBearer: long.request, now: now.addingTimeInterval(86399)) != nil)
    #expect(grants.grant(ofBearer: long.request, now: now.addingTimeInterval(86401)) == nil)
    let capped = grants.environment(spaceURL: "https://space.test", session: session, machine: machine, exec: ExecID(rawValue: "ex_cccccccc"), timeout: 3 * 86400, now: now)
    #expect(grants.grant(ofBearer: capped.request, now: now.addingTimeInterval(86401)) == nil)
  }

  // Grants live in memory: a restarted server holds none, and the grant it
  // issues when a v2 relay starts the exec again is a new capability, never
  // the old one. Likewise after a revoke within one server.
  @Test func aRestartOrRevokeNeverRevivesAnOldCapability() {
    let now = Date()
    let session = SessionID("s"), machine = MachineID(rawValue: "mc_a"), exec = ExecID(rawValue: "ex_aaaaaaaa")
    let before = IDTokenGrants()
    let old = before.environment(spaceURL: "https://space.test", session: session, machine: machine, exec: exec, timeout: 600, now: now)
    let after = IDTokenGrants()
    #expect(after.grant(ofBearer: old.request, now: now) == nil)
    let fresh = after.environment(spaceURL: "https://space.test", session: session, machine: machine, exec: exec, timeout: 600, now: now)
    #expect(fresh.request != old.request)
    #expect(after.grant(ofBearer: old.request, now: now) == nil)
    #expect(after.grant(ofBearer: fresh.request, now: now)?.exec == exec)
    after.revoke(exec)
    let again = after.environment(spaceURL: "https://space.test", session: session, machine: machine, exec: exec, timeout: 600, now: now)
    #expect(again.request != fresh.request)
    #expect(after.grant(ofBearer: fresh.request, now: now) == nil)
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
