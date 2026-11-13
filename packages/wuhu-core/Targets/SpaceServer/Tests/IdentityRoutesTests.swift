import Assertion
import Crypto
import Dependencies
import DeterministicDependencies
import Fetch
import Foundation
import JSONValue
import ServeTesting
import SpaceCore
@testable import SpaceServer
import Testing

@Suite(.deterministicDependencies) struct IdentityRoutesTests {
  @Test func onlyHumanAdminsMayRecordIdentityIntents() async throws {
    try await withSessionDeps {
      @Dependency(\.date) var date
      let tree = try await SessionGateTests().tree(dev: false)
      let identity = try await testIdentity()
      let harness = tree.harness
      let handler = SpaceServer.configuredHandler(space: harness.space, hub: harness.hub, sessions: harness.runtime, origin: "https://space.test", devPerson: nil, execTokens: tree.tokens, identityController: identity.controller)
      let api = ServeTesting.client(upgrading: handler)
      let url = URL(string: "https://space.test/v1/identity")!
      #expect(try await api(Request(url: url)).status == .unauthorized)
      var request = Request(url: url)
      request.headers[.authorization] = "Bearer " + tree.token
      #expect(try await api(request).status == .ok)
      for mutation in ["set", "rotate", "register-new"] {
        request.method = mutation == "set" ? .put : .post
        request.url = mutation == "set" ? url : url.appendingPathComponent(mutation)
        request.body = mutation == "set" ? try .json(["defaultIssuer": "self"]) : nil
        #expect(try await api(request).status == .forbidden)
      }
      for admin in [false, true] {
        let key = Curve25519.Signing.PrivateKey()
        let account = try await harness.space.addAccount(kind: .human, name: nil, admin: admin)
        _ = try await harness.space.addKey(key.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
        let assertion = try AssertionClaims(key: key.pubkeyLabel, space: await harness.space.identity().rawValue, expiresAt: date.now.addingTimeInterval(3600)).signed(by: key)
        request.headers[.authorization] = "Bearer " + assertion.rawValue
        request.url = url
        request.method = .put
        request.body = try .json(["defaultIssuer": "self"])
        #expect(try await api(request).status == (admin ? .ok : .forbidden))
        request.url = url.appendingPathComponent("rotate")
        request.method = .post
        request.body = nil
        let response = try await api(request)
        #expect(response.status == (admin ? .ok : .forbidden))
        if admin {
          let snapshot = try await response.json(JSONValue.self)
          #expect(snapshot.object?["rotating"] == true)
          #expect(try await api(request).status == .conflict)
        }
      }
      try await identity.controller.space.close()
    }
  }
}
