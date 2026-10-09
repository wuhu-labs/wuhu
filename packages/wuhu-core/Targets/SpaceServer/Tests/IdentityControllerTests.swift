import Assertion
import Crypto
import Dependencies
import DependenciesTestSupport
import Fetch
import Foundation
import JSONValue
import NIOCore
import ServeTesting
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import enum WuhuAI.InferenceError
import WuhuVFS

@Suite(.dependency(\.continuousClock, ContinuousClock())) struct IdentityControllerTests {
  @Test func inferenceSelectsIssuerAndRefusedRestartHasStaticTypedFailure() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let key = try await ServerIdentity.loadOrCreate(from: fs)
    let id = String(repeating: "i", count: 32)
    let controller = try IdentityController(identity: key, origin: "https://private.test", settings: .init(defaultIssuer: .directory, overrides: ["https://lab.test": .self], directoryID: id), store: .filesystem(fs), fetch: FetchClient { _ in try Response.json(["confirmed": true]) })
    try await controller.set(defaultIssuer: .directory)
    for (audience, issuer) in [("https://lab.test/v1", "https://private.test"), ("https://outside.test/v1", "https://id.wuhu.ai/" + id)] {
      let token = try await controller.tokenForInference(audience: URL(string: audience)!, space: "s", group: "g", session: "a", now: fixedDate, id: UUID(0))
      #expect(try claims(token).object?["iss"] == .string(issuer))
      try verify(token, jwks: key.jwks)
    }
    let reopened = try await IdentityController.load(identity: key, origin: "https://private.test", store: .filesystem(fs), fetch: FetchClient { _ in Response(status: .forbidden) })
    #expect(await reopened.settings.directoryID == id)
    await #expect(throws: InferenceError.invalidInput(status: 422, body: "OIDC directoryUnavailable: the key directory has not confirmed this server key; retry publication with wuhu identity set.")) {
      try await reopened.tokenForInference(audience: URL(string: "https://outside.test/v1")!, space: "s", group: "g", session: "a", now: fixedDate, id: UUID(0))
    }
    let selfToken = try await reopened.tokenForInference(audience: URL(string: "https://lab.test/v1")!, space: "s", group: "g", session: "a", now: fixedDate, id: UUID(0))
    #expect(try claims(selfToken).object?["iss"] == "https://private.test")
  }

  @Test(arguments: ["https://*.test", "custom://service"])
  func discoveryHTTPRejectsNonFetchOrigins(origin: String) async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let key = try await ServerIdentity.loadOrCreate(from: fs)
    let controller = try IdentityController(identity: key, origin: "https://space.test", store: .filesystem(fs), fetch: FetchClient { _ in Response(status: .forbidden) })
    let space = try makeMachineSpace()
    let api = ServeTesting.client(upgrading: SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), origin: "https://space.test", dev: true, webApp: nil, identityController: controller))
    var parts = URLComponents(string: "https://space.test/v1/identity/issuer-for")!
    parts.queryItems = [.init(name: "origin", value: origin)]
    let response = try await api(Request(url: parts.url!))
    #expect(response.status == .unprocessableContent)
    #expect(try await json(response).object?["code"] == "identityConfiguration")
  }

  @Test func concurrentSettingsWriteReturnsTypedBusyWithoutChangingConfiguration() async throws {
    let entered = Gate()
    let release = Gate()
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let key = try await ServerIdentity.loadOrCreate(from: fs)
    let controller = try IdentityController(identity: key, origin: "https://space.test", store: .filesystem(fs), fetch: FetchClient { _ in
      entered.open()
      await release.wait()
      return try Response.json(JSONValue.object(["id": .string(String(repeating: "b", count: 32)), "issuer": .string("https://id.wuhu.ai/" + String(repeating: "b", count: 32)), "confirmed": true]), status: .created)
    })
    let space = try makeMachineSpace()
    let api = ServeTesting.client(upgrading: SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), origin: "https://space.test", dev: true, webApp: nil, identityController: controller))
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { try await controller.set(defaultIssuer: .directory) }
      await entered.wait()
      let response = try await api(Request(url: URL(string: "https://space.test/v1/identity")!, method: .put, body: .json(["defaultIssuer": "self"])))
      release.open()
      #expect(response.status == .conflict)
      #expect(try await json(response).object?["code"] == "identityBusy")
      try await tasks.waitForAll()
    }
    #expect(await controller.settings.defaultIssuer == .directory)
  }

  @Test func defaultMakesNoDirectoryRequestAndMatchesExistingClaims() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let key = try await ServerIdentity.loadOrCreate(from: fs)
    let controller = try await IdentityController.load(identity: key, origin: "https://space.test", store: .filesystem(fs), fetch: FetchClient { _ in
      Issue.record("default identity must not contact the directory")
      return Response(status: .internalServerError)
    })
    #expect(try await controller.snapshot() == ["defaultIssuer": "https://space.test", "overrides": [:], "publicationFailure": .null])
    let audience = URL(string: "https://provider.test:443/v1")!
    let old = try key.token(issuer: "https://space.test", audience: audience, space: "s", group: "g", session: "a", now: fixedDate, id: UUID(0))
    let new = try await controller.token(audience: audience, space: "s", group: "g", session: "a", now: fixedDate, id: UUID(0))
    #expect(old.split(separator: ".").prefix(2) == new.split(separator: ".").prefix(2))
    #expect(await controller.jwks == key.jwks)
  }

  @Test func registrationAndStartupReplacementAreSignedRecordedEffects() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let key = try await ServerIdentity.loadOrCreate(from: fs)
    let requests = Mutex<[Request]>([])
    let id = String(repeating: "a", count: 32)
    let fetch = FetchClient { request in
      requests.withLock { $0.append(request) }
      return try Response.json(request.method == .post ? JSONValue.object(["id": .string(id), "issuer": .string("https://id.wuhu.ai/" + id), "confirmed": true]) : ["confirmed": true], status: request.method == .post ? .created : .ok)
    }
    let controller = try await IdentityController.load(identity: key, origin: "https://private.test", store: .filesystem(fs), fetch: fetch)
    try await withDependencies { $0.date = .constant(fixedDate) } operation: {
      try await controller.set(defaultIssuer: .directory)
    }
    try await controller.set(audience: "https://lab.test", choice: .self)
    #expect(try await controller.issuerFor(URL(string: "https://lab.test/page")!) == "https://private.test")
    #expect(try await controller.issuerFor(URL(string: "https://outside.test/v1")!) == "https://id.wuhu.ai/" + id)
    let jwt = try await controller.token(audience: URL(string: "https://outside.test")!, space: "s", group: "g", now: fixedDate, id: UUID(1))
    #expect(try claims(jwt).object?["iss"] == .string("https://id.wuhu.ai/" + id))
    let reopened = try await IdentityController.load(identity: key, origin: "https://private.test", store: .filesystem(fs), fetch: fetch)
    #expect(try await controller.snapshot() == reopened.snapshot())
    #expect(await reopened.directoryConfirmed)
    let recorded = requests.withLock { $0 }
    #expect(recorded.map(\.method) == [.post, .put, .put])
    #expect(recorded.map { $0.url.absoluteString } == ["https://id.wuhu.ai/register", "https://id.wuhu.ai/" + id + "/keys", "https://id.wuhu.ai/" + id + "/keys"])
    var registrationProof = ""
    for request in recorded {
      let proof = try await request.body!.text()
      if request.method == .post { registrationProof = proof }
      let payload = try claims(proof)
      #expect(payload.object?["aud"] == .string(request.url.absoluteString))
      #expect(payload.object?["jwks"] == key.jwks)
      #expect(!payload.jsonString().contains("private.test"))
      #expect(payload.object?.keys.sorted() == ["aud", "exp", "iat", "jti", "jwks"])
      try verify(proof, jwks: key.jwks)
    }
    if ProcessInfo.processInfo.environment["WUHU_EXPORT_IDENTITY_FIXTURE"] == "1" {
      let fixture: JSONValue = .object(["registrationProof": .string(registrationProof), "token": .string(jwt), "jwks": key.jwks, "issuer": .string("https://id.wuhu.ai/" + id), "audience": "https://outside.test", "now": .integer(Int(fixedDate.timeIntervalSince1970))])
      let output = try #require(ProcessInfo.processInfo.environment["TEST_UNDECLARED_OUTPUTS_DIR"])
      try Data(fixture.jsonString().utf8).write(to: URL(fileURLWithPath: output).appendingPathComponent("swift_identity_fixture.json"))
    }
    let space = try makeMachineSpace()
    let handler = withDependencies { $0.continuousClock = ContinuousClock() } operation: {
      SpaceServer.configuredHandler(space: space, hub: MachineHub(space: space), origin: "https://private.test", dev: true, webApp: nil, identityController: reopened)
    }
    let api = ServeTesting.client(upgrading: handler)
    #expect(try await json(try await api(Request(url: URL(string: "https://private.test/.well-known/openid-configuration")!))).object?["issuer"] == .string("https://private.test"))
    #expect(try await json(try await api(Request(url: URL(string: "https://private.test/v1/identity")!))) == reopened.snapshot())
  }

  @Test func refusalPersistsChoiceButNeverFallsBackAndReopenRetries() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let key = try await ServerIdentity.loadOrCreate(from: fs)
    let fetch = FetchClient { _ in Response(status: .forbidden) }
    let controller = try await IdentityController.load(identity: key, origin: "https://space.test", store: .filesystem(fs), fetch: fetch)
    await #expect(throws: IdentityError.directoryUnavailable) { try await controller.set(defaultIssuer: .directory) }
    await #expect(throws: IdentityError.directoryUnavailable) {
      try await controller.token(audience: URL(string: "https://provider.test")!, space: "s", group: "g", now: fixedDate, id: UUID(0))
    }
    let reopened = try await IdentityController.load(identity: key, origin: "https://space.test", store: .filesystem(fs), fetch: fetch)
    #expect(await reopened.settings.defaultIssuer == .directory)
    #expect(await reopened.directoryConfirmed == false)
    try await reopened.set(defaultIssuer: .self)
    #expect(try await reopened.issuerFor(URL(string: "https://provider.test")!) == "https://space.test")
  }

  @Test func directoryFailureIsTypedForPageAndScriptWithoutAnyRequest() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let key = try await ServerIdentity.loadOrCreate(from: fs)
    let controller = try IdentityController(identity: key, origin: "https://private.test", settings: .init(defaultIssuer: .directory), store: .filesystem(fs), fetch: FetchClient { _ in Response(status: .forbidden) })
    let page = PageFetch(controller: controller, hop: { _, _ in Issue.record("unconfirmed identity must not connect"); return Response(status: .ok) })
    do {
      _ = try await page.response(Request(url: URL(string: "https://outside.test")!), allow: ["https://outside.test"], space: "s", group: "g", page: "/page", viewer: "v", deadline: .now() + .seconds(60))
      Issue.record("page minted an unconfirmed directory token")
    } catch let error as PageFetchError { #expect(error.code == "directoryUnavailable") }
    let script = ScriptFetch(controller: controller, hop: { _, _ in Issue.record("unconfirmed identity must not connect"); return Response(status: .ok) })
    try await withIdentityScript(proxy: script) { rig in
      let output = try await rig.evaluate("try {await fetch('https://outside.test', {identity:true})} catch(e) {result(e.code)}")
      #expect(output == "directoryUnavailable")
    }
  }

  @Test func scriptAndPageSelectTheSameAudienceOverride() async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let key = try await ServerIdentity.loadOrCreate(from: fs)
    let id = String(repeating: "a", count: 32)
    let controller = try IdentityController(identity: key, origin: "https://private.test", settings: .init(defaultIssuer: .directory, overrides: ["https://lab.test": .self], directoryID: id), store: .filesystem(fs), fetch: FetchClient { _ in try Response.json(["confirmed": true]) })
    try await controller.publish()
    let sent = Mutex<[String]>([])
    let hop: @Sendable (Request, NIODeadline) async throws -> Response = { request, _ in
      let token = String(try #require(request.headers[.authorization]).dropFirst(7))
      sent.withLock { $0.append(token) }
      try verify(token, jwks: key.jwks)
      return Response(status: .ok, body: .string("ok"))
    }
    for origin in ["https://lab.test", "https://outside.test"] {
      let page = PageFetch(controller: controller, hop: hop)
      _ = try await page.response(Request(url: URL(string: origin + "/path")!), allow: [origin], space: "s", group: "g", page: "/page", viewer: "v", deadline: .now() + .seconds(60))
      try await withIdentityScript(proxy: ScriptFetch(controller: controller, hop: hop)) { rig in
        let output = try await rig.evaluate("result(await (await fetch('\(origin)/path', {identity:true})).text())")
        #expect(output == "ok")
      }
    }
    let issuers = try sent.withLock { $0 }.map { try claims($0).object?["iss"] }
    #expect(issuers == ["https://private.test", "https://private.test", .string("https://id.wuhu.ai/" + id), .string("https://id.wuhu.ai/" + id)])
  }

  @Test func sessionReadsButCannotChangeServerSettingsAndHumanWritesNeedSpaceAdmin() async throws {
    try await withSessionDeps {
      let tree = try await SessionGateTests().tree(dev: false)
      let fs = NodeTreeVFS(root: InMemoryVFSNode())
      let key = try await ServerIdentity.loadOrCreate(from: fs)
      let controller = try IdentityController(identity: key, origin: "https://space.test", store: .filesystem(fs), fetch: FetchClient { _ in Response(status: .forbidden) })
      let harness = tree.harness
      let handler = SpaceServer.configuredHandler(space: harness.space, hub: harness.hub, sessions: harness.runtime, origin: "https://space.test", dev: false, webApp: nil, execTokens: tree.tokens, identityController: controller)
      let api = ServeTesting.client(upgrading: handler)
      var request = Request(url: URL(string: "https://space.test/v1/identity")!)
      #expect(try await api(request).status == .unauthorized)
      request.headers[.authorization] = "Bearer " + tree.token
      #expect(try await api(request).status == .ok)
      request.method = .put
      request.body = try .json(["defaultIssuer": "self"])
      #expect(try await api(request).status == .forbidden)
      var rotateRequest = request
      rotateRequest.url = URL(string: "https://space.test/v1/identity/rotate")!
      rotateRequest.method = .post
      rotateRequest.body = nil
      #expect(try await api(rotateRequest).status == .forbidden)
      var registrationRequest = rotateRequest
      registrationRequest.url = URL(string: "https://space.test/v1/identity/register-new")!
      #expect(try await api(registrationRequest).status == .forbidden)
      for admin in [false, true] {
        let signingKey = Curve25519.Signing.PrivateKey()
        let account = try await harness.space.addAccount(kind: .human, name: nil, admin: admin)
        _ = try await harness.space.addKey(signingKey.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
        let spaceID = try await harness.space.identity().rawValue
        let assertion = try AssertionClaims(key: signingKey.pubkeyLabel, space: spaceID, expiresAt: Date().addingTimeInterval(3600)).signed(by: signingKey)
        request.headers[.authorization] = "Bearer " + assertion.rawValue
        #expect(try await api(request).status == (admin ? .ok : .forbidden))
        rotateRequest.headers = request.headers
        #expect(try await api(rotateRequest).status == (admin ? .ok : .forbidden))
        registrationRequest.headers = request.headers
        #expect(try await api(registrationRequest).status == (admin ? .conflict : .forbidden))
      }
      #expect(await controller.settings.defaultIssuer == .self)
    }
  }

  @Test(arguments: ["https://id.wuhu.ai/evil", "https://example.test/path", "https://user@example.test", "https://*.test", "https://example.test:443", "https://EXAMPLE.test", "https://example.test/"])
  func invalidOverrideDoesNotPersist(origin: String) async throws {
    let fs = NodeTreeVFS(root: InMemoryVFSNode())
    let key = try await ServerIdentity.loadOrCreate(from: fs)
    let controller = try IdentityController(identity: key, origin: "https://space.test", store: .filesystem(fs), fetch: FetchClient { _ in Response(status: .ok) })
    await #expect(throws: IdentityError.invalidAudience) { try await controller.set(audience: origin, choice: .directory) }
    #expect(await controller.settings.overrides.isEmpty)
  }
}

private func claims(_ token: String) throws -> JSONValue {
  try #require(JSONValue.parse(String(decoding: decode(String(token.split(separator: ".")[1])), as: UTF8.self)))
}

private func decode(_ value: String) throws -> Data {
  let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  return try #require(Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)))
}

private func verify(_ token: String, jwks: JSONValue) throws {
  let parts = token.split(separator: ".").map(String.init)
  let jwk = try #require(jwks.object?["keys"]?.array?.first?.object)
  let point = Data([4]) + (try decode(#require(jwk["x"]?.stringValue))) + (try decode(#require(jwk["y"]?.stringValue)))
  let key = try P256.Signing.PublicKey(x963Representation: point)
  #expect(try key.isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2])), for: Data((parts[0] + "." + parts[1]).utf8)))
}
