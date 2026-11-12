import Assertion
import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import JSONValue
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineContract
import Scratch
import ServeTesting
import SessionDomain
@testable import SessionTools
import SpaceContract
import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing

@Suite(.deterministicDependencies) struct SignedCredentialTests {
  @Test func credentialsSurviveOverlappingWorkersButNotEndedExecs() async throws {
    try await withSessionDeps {
      let folder = try ScratchFolder("credential-rollover")
      let file = folder.url.appendingPathComponent("space.sqlite")
      let old = try Space.open(file: file)
      let new = try Space.open(file: file)
      do {
        let keys = MemoryFiles().identityKeys
        let fetch = FetchClient { _ in Response(status: .forbidden) }
        let first = IdentityController.configure(space: old, origin: nil, keys: keys, fetch: fetch)
        let second = IdentityController.configure(space: new, origin: nil, keys: keys, fetch: fetch)
        try await first.initialize(identity: ServerIdentity.generate())
        old.worker.start()
        let model = SessionExecutor.kernel(ModelSpecifier(provider: "testing", model: "test-model", effort: "high"))
        let session = try await old.sessions.createSession(group: .shared, title: "rollover", kind: .agent, createdBy: "owner", executor: model)
        let machine = try await old.addMachineV2(name: "box").machine
        let exec = try await old.reserveExec(machine: machine.id, caller: session.rawValue)
        let before = ExecTokens(spaceURL: "http://lan", identity: first)
        let token = try await before.credential(session: session, exec: exec.id, timeout: 600, now: Date()).token
        let sessionToken = try await before.sessionToken(session)
        new.worker.start()
        await old.worker.quiesce()
        old.worker.release()
        let after = ExecTokens(spaceURL: "http://lan", identity: second)
        for bearer in [token, sessionToken] {
          guard case let .session(principal) = await sessionVerdict(bearer, tokens: after, space: new, now: Date()) else { Issue.record("credential did not survive rollover"); continue }
          #expect(principal.session == session)
          #expect(principal.exec == (bearer == token))
        }
        try await setExecTerminalFixture(space: new, exec: exec.id, terminal: .exited(code: 0))
        guard case .refused = await sessionVerdict(token, tokens: after, space: new, now: Date()) else { throw InvalidCredentialTestState() }
      } catch {
        try await old.close()
        try await new.close()
        throw error
      }
      try await old.close()
      try await new.close()
    }
  }

  @Test func aRetainedClientCanBackgroundAnExecAfterItsFirstBearerExpires() async throws {
    try await withSessionDeps {
      let now = Mutex(Date())
      try await withDependencies { $0.date = DateGenerator { now.withLock { $0 } } } operation: {
        let t = try await SessionGateTests().tree()
        let record = try #require(try await t.harness.space.execRecord(t.exec))
        let executor = SessionRuntime.toolExecutor(owner: t.harness.runtime.owner, tokens: t.tokens, hub: t.harness.hub)
        let client = executor.client(t.parent)
        let _: JSONValue = try await client.api(.get, "/v1/machine")
        now.withLock { $0 = $0.addingTimeInterval(301) }
        let exec = try await t.harness.space.reserveExec(machine: record.machine, caller: t.parent.rawValue, toolCall: ToolCallID(rawValue: "tc-retained-client")).id
        let _: JSONValue = try await client.api(.post, "/v1/exec/\(exec.rawValue)/background")
        #expect(try await t.harness.space.execRecord(exec)?.background == true)
      }
    }
  }

  @Test func unprefixedJWTsPassToTheNextGate() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree(dev: false)
      let gate = sessionGate(
        space: t.harness.space, hub: t.harness.hub, machines: machineSeam(hub: t.harness.hub), owner: t.harness.runtime.owner,
        tokens: t.tokens, runtime: t.harness.runtime, credentials: .unavailable, identity: nil, metrics: .noop,
        routed: { _ in .response(Response(status: .notImplemented)) }, otherwise: { _ in .response(Response(status: .accepted)) },
      )
      let client = ServeTesting.client(upgrading: gate)
      let jwt = String(t.token.dropFirst(ExecTokens.prefix.count))
      #expect(!isSessionBearer(jwt))
      var request = Request(url: URL(string: "http://main/v1/session-tools")!)
      request.headers[.authorization] = "Bearer " + jwt
      #expect(try await client(request).status == .accepted)
      let device = P256.Signing.PrivateKey()
      let account = try await t.harness.space.addAccount(kind: .human, name: nil)
      _ = try await t.harness.space.addKey(device.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
      let space = try await t.harness.space.identity().rawValue
      let assertion = try AssertionClaims(key: device.pubkeyLabel, space: space, expiresAt: Date().addingTimeInterval(300)).signed(by: device)
      #expect(try await t.harness.get("/v1/machine", bearer: assertion.rawValue).status == .ok)
      request.headers[.authorization] = "Bearer " + ExecTokens.prefix + "invalid"
      #expect(try await client(request).status == .unauthorized)
    }
  }

  @Test func signatureSpacePurposeAndExpiryAreChecked() async throws {
    try await withSessionDeps {
      let t = try await SessionGateTests().tree()
      let identity = t.tokens.identity
      let key = try await identity.keys.load(identity.state!.schedule.signer)
      let space = try await t.harness.space.identity().rawValue
      let issuer = "wuhu:space:" + space
      let now = Date()
      func token(issuer selectedIssuer: String? = nil, audience: String? = nil, boundSpace: String? = nil, group: String = "shared", purpose: String? = "exec", machine: String = "mc_wrong", exec: String? = nil) throws -> String {
        let signed = try key.token(issuer: nil, audience: URL(string: audience ?? issuer)!, space: boundSpace ?? space, group: group, session: t.parent.rawValue, now: now, id: UUID(), lifetime: 60, exec: .init(machine: machine, exec: exec ?? t.exec.rawValue), directoryIssuer: selectedIssuer ?? issuer, purpose: purpose ?? "remove")
        guard purpose == nil else { return ExecTokens.prefix + signed }
        let parts = signed.split(separator: ".").map(String.init)
        var fields = JSONValue.parse(String(decoding: credentialTestPart(parts[1]), as: UTF8.self))!.object!
        fields.removeValue(forKey: "credential")
        let input = parts[0] + "." + credentialTestBase64(Data(JSONValue.object(fields).jsonString().utf8))
        let signer = try P256.Signing.PrivateKey(rawRepresentation: key.rawKey)
        return ExecTokens.prefix + input + "." + credentialTestBase64(try signer.signature(for: Data(input.utf8)).rawRepresentation)
      }
      let machine = try #require(try await t.harness.space.execRecord(t.exec)).machine.rawValue
      let invalid = try [
        token(issuer: "wuhu:space:other", machine: machine),
        token(audience: "https://external.test", machine: machine),
        token(boundSpace: "other", machine: machine),
        token(purpose: nil, machine: machine),
        token(machine: machine, exec: "ex_missing"),
      ]
      for bearer in invalid {
        guard case .refused = await sessionVerdict(bearer, tokens: t.tokens, space: t.harness.space, now: now) else { Issue.record("invalid claims accepted"); continue }
      }
      var parts = t.token.split(separator: ".").map(String.init)
      parts[2] = String(repeating: "A", count: parts[2].count)
      guard case .refused = await sessionVerdict(parts.joined(separator: "."), tokens: t.tokens, space: t.harness.space, now: now) else { Issue.record("forged signature accepted"); return }
      guard case .refused = await sessionVerdict(t.token, tokens: t.tokens, space: t.harness.space, now: now.addingTimeInterval(86401)) else { Issue.record("expired token accepted"); return }
      let own = try await t.tokens.sessionToken(t.parent)
      let ownClaims = try #require(try await identity.credential(String(own.dropFirst(ExecTokens.prefix.count))))
      #expect(ownClaims.exp - ownClaims.iat == 300)
      #expect(ownClaims.machine == nil && ownClaims.exec == nil)
      let capped = try await t.tokens.credential(session: t.parent, exec: t.exec, timeout: 7 * 86400, now: now).token
      let cappedClaims = try #require(try await identity.credential(String(capped.dropFirst(ExecTokens.prefix.count))))
      #expect(cappedClaims.exp - cappedClaims.iat == 86400)
      let mismatch = try await identity.credential(session: t.parent, group: .init(rawValue: "other"), exec: nil, now: now, lifetime: 60)
      guard case let .refused(groupResponse) = await sessionVerdict(ExecTokens.prefix + mismatch, tokens: t.tokens, space: t.harness.space, now: now) else { throw InvalidCredentialTestState() }
      #expect(groupResponse.status == .forbidden)
      let reminted = try await t.tokens.credential(session: t.parent, exec: t.exec, timeout: 7 * 86400, now: now).token
      #expect(try await identity.credential(String(reminted.dropFirst(ExecTokens.prefix.count)))?.exp == cappedClaims.exp)
      for audience in [issuer, "ftp://external.test"] {
        #expect(try await t.harness.get("/v1/id-token", query: ["audience": audience], bearer: t.token).status == .badRequest)
      }
    }
  }
}

private struct InvalidCredentialTestState: Error {}

private func credentialTestPart(_ value: String) -> Data {
  let text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  return Data(base64Encoded: text + String(repeating: "=", count: (4 - text.count % 4) % 4))!
}

private func credentialTestBase64(_ data: Data) -> String {
  data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
