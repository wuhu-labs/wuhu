import Assertion
import Crypto
import Fetch
import Foundation
import JSONValue
import SpaceCore
import Testing

@Suite struct UserManagementRouteTests {
  let harness: Harness
  let identity: String

  init() async throws {
    harness = try Harness(dev: false)
    identity = try await harness.space.identity().rawValue
  }

  func user(
    name: String? = nil,
    admin: Bool = false,
  ) async throws -> (record: AccountRecord, key: Curve25519.Signing.PrivateKey) {
    let record = try await harness.space.addAccount(kind: .human, name: name, admin: admin)
    let key = Curve25519.Signing.PrivateKey()
    _ = try await harness.space.addKey(key.pubkeyLabel, account: record.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    return (record, key)
  }

  func send(
    _ method: Fetch.Method,
    _ path: String,
    body: JSONValue? = nil,
    key: Curve25519.Signing.PrivateKey?,
  ) async throws -> Response {
    var request = Request(url: URL(string: "http://space" + path)!, method: method)
    if let body {
      request.body = .bytes(Data(body.jsonString().utf8), contentType: "application/json")
    }
    if let key {
      let assertion = try AssertionClaims(
        key: key.pubkeyLabel,
        space: identity,
        expiresAt: fixedDate.addingTimeInterval(3600),
      ).signed(by: key)
      request.headers[.authorization] = "Bearer " + assertion.rawValue
    }
    return try await harness.api(request)
  }

  @Test func enrollMintIsSelfOrAdmin() async throws {
    let alice = try await user(name: "alice")
    let root = try await user(name: "root", admin: true)
    let bob = try await harness.space.addAccount(kind: .human, name: "bob")

    let own = try await send(.post, "/v1/enroll", body: .object([
      "account": .string(alice.record.id.rawValue), "capabilities": .array([.string("device")]),
    ]), key: alice.key)
    #expect(own.status == .ok)
    let token = try #require((try await json(own)).stringValue(at: "token"))
    let minted = try await harness.space.consumeJoinToken(JoinToken(rawValue: token), pubkey: testPubkey("phone"))
    #expect(minted.account == alice.record.id)
    #expect(minted.createdBy == alice.record.id)

    let foreign = try await send(.post, "/v1/enroll", body: .object([
      "account": .string(bob.id.rawValue), "capabilities": .array([.string("device")]),
    ]), key: alice.key)
    #expect(foreign.status == .forbidden)
    #expect((try await json(foreign)).stringValue(at: "code") == "adminRequired")

    let granted = try await send(.post, "/v1/enroll", body: .object([
      "account": .string(bob.id.rawValue), "capabilities": .array([.string("device")]),
    ]), key: root.key)
    #expect(granted.status == .ok)
  }

  @Test func enrollRevokeIsSelfOrAdmin() async throws {
    let alice = try await user(name: "alice")
    let root = try await user(name: "root", admin: true)
    let bob = try await harness.space.addAccount(kind: .human, name: "bob")
    let bobsInvite = try await harness.space.mintJoinToken(
      account: bob.id, capabilities: [.device], createdBy: nil, lifetime: 600,
    )

    let foreign = try await send(.post, "/v1/enroll/revoke", body: .object([
      "token": .string(bobsInvite.token.rawValue),
    ]), key: alice.key)
    #expect(foreign.status == .forbidden)
    #expect((try await json(foreign)).stringValue(at: "code") == "adminRequired")
    #expect(try await harness.space.consumeJoinToken(bobsInvite.token, pubkey: testPubkey("bob")).account == bob.id)

    let own = try await harness.space.mintJoinToken(
      account: alice.record.id, capabilities: [.device], createdBy: nil, lifetime: 600,
    )
    #expect(try await send(.post, "/v1/enroll/revoke", body: .object([
      "token": .string(own.token.rawValue),
    ]), key: alice.key).status == .ok)

    let adminReach = try await harness.space.mintJoinToken(
      account: bob.id, capabilities: [.device], createdBy: nil, lifetime: 600,
    )
    #expect(try await send(.post, "/v1/enroll/revoke", body: .object([
      "token": .string(adminReach.token.rawValue),
    ]), key: root.key).status == .ok)
  }

  @Test func selfKeyListAndRevokeRoundtrip() async throws {
    let alice = try await user(name: "alice")
    let second = Curve25519.Signing.PrivateKey()
    _ = try await harness.space.addKey(second.pubkeyLabel, account: alice.record.id, capabilities: [.device], createdBy: nil, expiresAt: nil)

    let listed = try await send(.get, "/v1/keys", key: alice.key)
    #expect(listed.status == .ok)
    let keys = try #require((try await json(listed)).arrayValue(at: "keys"))
    #expect(Set(keys.compactMap { $0.stringValue(at: "pubkey") }) == [alice.key.pubkeyLabel, second.pubkeyLabel])
    #expect(keys.allSatisfy { $0.stringValue(at: "account") == alice.record.id.rawValue })

    let revoked = try await send(.delete, "/v1/key", body: .object(["pubkey": .string(second.pubkeyLabel)]), key: alice.key)
    #expect(revoked.status == .ok)
    #expect(try await harness.space.credential(pubkey: second.pubkeyLabel) == nil)
    let remaining = try await send(.get, "/v1/keys", key: alice.key)
    #expect((try await json(remaining)).arrayValue(at: "keys")?.count == 1)
  }

  @Test func anotherAccountsKeysNeedAdmin() async throws {
    let alice = try await user(name: "alice")
    let bob = try await user(name: "bob")
    let root = try await user(name: "root", admin: true)

    let peeked = try await send(.get, "/v1/keys?account=\(bob.record.id.rawValue)", key: alice.key)
    #expect(peeked.status == .forbidden)
    #expect((try await json(peeked)).stringValue(at: "code") == "adminRequired")

    let stabbed = try await send(.delete, "/v1/key", body: .object(["pubkey": .string(bob.key.pubkeyLabel)]), key: alice.key)
    #expect(stabbed.status == .forbidden)
    #expect(try await harness.space.credential(pubkey: bob.key.pubkeyLabel) != nil)

    let audited = try await send(.get, "/v1/keys?account=\(bob.record.id.rawValue)", key: root.key)
    #expect(audited.status == .ok)
    #expect((try await json(audited)).arrayValue(at: "keys")?.count == 1)

    let kicked = try await send(.delete, "/v1/key", body: .object(["pubkey": .string(bob.key.pubkeyLabel)]), key: root.key)
    #expect(kicked.status == .ok)
    #expect(try await harness.space.credential(pubkey: bob.key.pubkeyLabel) == nil)

    let ghost = try await send(.delete, "/v1/key", body: .object(["pubkey": .string(testPubkey("ghost"))]), key: root.key)
    #expect(ghost.status == .notFound)
  }

  @Test func accountLifecycleIsAdminOnly() async throws {
    let alice = try await user(name: "alice")
    let root = try await user(name: "root", admin: true)

    for (method, path, body): (Fetch.Method, String, JSONValue?) in [
      (.post, "/v1/accounts", .object(["name": .string("carol")])),
      (.get, "/v1/accounts", nil),
      (.delete, "/v1/accounts/\(alice.record.id.rawValue)", nil),
      (.post, "/v1/accounts/\(alice.record.id.rawValue)/admin", .object(["admin": .bool(true)])),
    ] {
      let refused = try await send(method, path, body: body, key: alice.key)
      #expect(refused.status == .forbidden, "\(method) \(path)")
      #expect((try await json(refused)).stringValue(at: "code") == "adminRequired", "\(method) \(path)")
    }

    let created = try await send(.post, "/v1/accounts", body: .object(["name": .string("carol")]), key: root.key)
    #expect(created.status == .ok)
    let carol = try await json(created)
    let carolID = try #require(carol.stringValue(at: "id"))
    #expect(AccountID.isValid(carolID))
    #expect(carol["admin"] == .bool(false))

    let reserved = try await send(.post, "/v1/accounts", body: .object(["name": .string("Owner")]), key: root.key)
    #expect(reserved.status == .badRequest)
    #expect((try await json(reserved)).stringValue(at: "code") == "reservedAccountName")

    let roster = try await send(.get, "/v1/accounts", key: root.key)
    #expect(roster.status == .ok)
    let ids = try #require((try await json(roster)).arrayValue(at: "accounts")).compactMap { $0.stringValue(at: "id") }
    #expect(ids.contains(carolID))
    #expect(ids.contains(alice.record.id.rawValue))

    let promoted = try await send(.post, "/v1/accounts/\(carolID)/admin", body: .object(["admin": .bool(true)]), key: root.key)
    #expect(promoted.status == .ok)
    #expect((try await json(promoted))["admin"] == .bool(true))
    let demoted = try await send(.post, "/v1/accounts/\(carolID)/admin", body: .object(["admin": .bool(false)]), key: root.key)
    #expect(demoted.status == .ok)
    #expect(try await harness.space.account(AccountID(rawValue: carolID))?.isAdmin == false)
  }

  @Test func removingAnAccountKillsItsCredentialsAndKeepsTheHistory() async throws {
    let alice = try await user(name: "alice")
    let root = try await user(name: "root", admin: true)
    let readSession = try await harness.space.createReadSession(
      account: alice.record.id,
      group: .shared,
      expiresAt: fixedDate.addingTimeInterval(3600),
    )
    let persona = try await harness.space.mintPersona(
      key: try #require(try await harness.space.credential(pubkey: alice.key.pubkeyLabel)),
    )

    let removed = try await send(.delete, "/v1/accounts/\(alice.record.id.rawValue)", key: root.key)
    #expect(removed.status == .ok)
    let payload = try await json(removed)
    #expect(payload["keys"] == .integer(1))
    #expect(payload["readSessions"] == .integer(1))

    // The kicked account is dead at its very next request; attribution stays.
    #expect(try await send(.get, "/v1/keys", key: alice.key).status == .unauthorized)
    #expect(try await harness.space.account(readSession: readSession, in: .shared) == nil)
    #expect(try await harness.space.persona(named: persona.name)?.account == alice.record.id)

    let roster = try await send(.get, "/v1/accounts", key: root.key)
    let ids = try #require((try await json(roster)).arrayValue(at: "accounts")).compactMap { $0.stringValue(at: "id") }
    #expect(!ids.contains(alice.record.id.rawValue))

    #expect(try await send(.delete, "/v1/accounts/\(alice.record.id.rawValue)", key: root.key).status == .notFound)
    #expect(try await send(.delete, "/v1/accounts/not-an-id", key: root.key).status == .badRequest)
  }

  @Test func theLastAdminCanNeitherBeDemotedNorRemoved() async throws {
    let root = try await user(name: "root", admin: true)
    _ = try await user(name: "alice")

    for (method, path, body): (Fetch.Method, String, JSONValue?) in [
      (.post, "/v1/accounts/\(root.record.id.rawValue)/admin", .object(["admin": .bool(false)])),
      (.delete, "/v1/accounts/\(root.record.id.rawValue)", nil),
    ] {
      let refused = try await send(method, path, body: body, key: root.key)
      #expect(refused.status == .conflict, "\(method) \(path)")
      let payload = try await json(refused)
      #expect(payload.stringValue(at: "code") == "lastAdmin", "\(method) \(path)")
      #expect(payload.stringValue(at: "hint")?.contains("wuhu user add") == true, "\(method) \(path)")
    }
    #expect(try await harness.space.account(root.record.id)?.isAdmin == true)
  }

  @Test func machineAndContractorAccountsAreNotRemovableHere() async throws {
    let root = try await user(name: "root", admin: true)
    let machine = try await harness.space.addMachine(name: "box")
    let refused = try await send(.delete, "/v1/accounts/\(machine.account.rawValue)", key: root.key)
    #expect(refused.status == .conflict)
    #expect((try await json(refused)).stringValue(at: "hint")?.contains("machine revoke") == true)
  }

  @Test func theDevSeatActsAsAdminAndHasNoAccountOfItsOwn() async throws {
    let dev = try Harness(dev: true)
    let created = try await dev.api(Request(
      url: URL(string: "http://space/v1/accounts")!,
      method: .post,
      body: .bytes(Data(JSONValue.object(["name": .string("carol")]).jsonString().utf8), contentType: "application/json"),
    ))
    #expect(created.status == .ok)
    let id = try #require((try await json(created)).stringValue(at: "id"))

    let listed = try await dev.get(dev.api, "/v1/keys", query: ["account": id])
    #expect(listed.status == .ok)

    let unaddressed = try await dev.get(dev.api, "/v1/keys")
    #expect(unaddressed.status == .badRequest)
  }
}

private extension JSONValue {
  subscript(_ key: String) -> JSONValue? {
    guard case let .object(fields) = self else { return nil }
    return fields[key]
  }

  func stringValue(at key: String) -> String? {
    guard case let .string(value)? = self[key] else { return nil }
    return value
  }

  func arrayValue(at key: String) -> [JSONValue]? {
    guard case let .array(values)? = self[key] else { return nil }
    return values
  }
}
