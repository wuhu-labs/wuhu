import Assertion
import Crypto
import Fetch
import Foundation
import JSONValue
import enum SpaceContract.ShareLogin
import SpaceCore
import Testing

@Suite
struct EnrollRoutesTests {
  @Test func mintedTokenConsumesOnceThenDies() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: "alice")

    let minted = try await postJSON(harness, "/v1/enroll", [
      "account": .string(account.id.rawValue),
      "capabilities": .array([.string("device"), .string("exec-machine")]),
    ])
    #expect(minted.status == .ok)
    let token = try #require((try await json(minted)).stringValue(at: "token"))
    #expect(token.hasPrefix("jt_"))

    let consumed = try await postJSON(harness, "/v1/enroll/consume", [
      "token": .string(token), "pubkey": .string(testPubkey("phone")),
    ])
    #expect(consumed.status == .ok)
    let payload = try await json(consumed)
    #expect(payload.stringValue(at: "account") == account.id.rawValue)
    #expect(payload["capabilities"] == .array([.string("device"), .string("exec-machine")]))
    #expect(try await harness.space.credential(pubkey: testPubkey("phone"))?.account == account.id)

    let second = try await postJSON(harness, "/v1/enroll/consume", [
      "token": .string(token), "pubkey": .string(testPubkey("thief")),
    ])
    #expect(second.status == .unauthorized)
    #expect((try await json(second)).stringValue(at: "code") == "tokenInvalid")
    #expect(try await harness.space.credential(pubkey: testPubkey("thief")) == nil)
  }

  @Test func revokingAMintedTokenStopsItFromEnrolling() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: "alice")

    let minted = try await postJSON(harness, "/v1/enroll", [
      "account": .string(account.id.rawValue),
      "capabilities": .array([.string("device")]),
    ])
    let token = try #require((try await json(minted)).stringValue(at: "token"))

    #expect(try await postJSON(harness, "/v1/enroll/revoke", ["token": .string(token)]).status == .ok)

    let consumed = try await postJSON(harness, "/v1/enroll/consume", [
      "token": .string(token), "pubkey": .string(testPubkey("phone")),
    ])
    #expect(consumed.status == .unauthorized)
    #expect(try await harness.space.credential(pubkey: testPubkey("phone")) == nil)

    let again = try await postJSON(harness, "/v1/enroll/revoke", ["token": .string(token)])
    #expect(again.status == .notFound)
    #expect((try await json(again)).stringValue(at: "code") == "notFound")
    #expect(try await postJSON(harness, "/v1/enroll/revoke", ["token": .string("not a token")]).status == .notFound)
  }

  @Test func consumeRejectsAMalformedPubkeyAndKeepsTheToken() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let minted = try await harness.space.mintJoinToken(account: account.id, capabilities: [.device], createdBy: nil, lifetime: 600)
    for junk in ["", "phone", "ed25519:phone"] {
      let rejected = try await postJSON(harness, "/v1/enroll/consume", [
        "token": .string(minted.token.rawValue), "pubkey": .string(junk),
      ])
      #expect(rejected.status == .badRequest)
      #expect((try await json(rejected)).stringValue(at: "code") == "invalidArgument")
    }
    #expect(try await harness.space.keys(account: account.id) == [])
    let consumed = try await postJSON(harness, "/v1/enroll/consume", [
      "token": .string(minted.token.rawValue), "pubkey": .string(testPubkey("recovered")),
    ])
    #expect(consumed.status == .ok)
  }

  @Test func consumeNamesTheMachineOnlyForAMachineAccountToken() async throws {
    let harness = try Harness()
    let machine = try await harness.space.addMachine(name: "box")
    let minted = try await harness.space.mintJoinToken(
      account: machine.account, capabilities: [.execMachine], createdBy: nil, lifetime: 600,
    )
    let consumed = try await postJSON(harness, "/v1/enroll/consume", [
      "token": .string(minted.token.rawValue), "pubkey": .string(testPubkey("box")),
    ])
    #expect(consumed.status == .ok)
    let payload = try await json(consumed)
    #expect(payload.stringValue(at: "machine") == machine.id.rawValue)
    #expect(payload.stringValue(at: "machineName") == "box")

    let human = try await harness.space.addAccount(kind: .human, name: nil)
    let deviceToken = try await harness.space.mintJoinToken(
      account: human.id, capabilities: [.device], createdBy: nil, lifetime: 600,
    )
    let devicePayload = try await json(try await postJSON(harness, "/v1/enroll/consume", [
      "token": .string(deviceToken.token.rawValue), "pubkey": .string(testPubkey("phone")),
    ]))
    #expect(devicePayload.stringValue(at: "machine") == nil)
  }

  @Test func mintValidatesAccountAndCapabilities() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)

    #expect(try await postJSON(harness, "/v1/enroll", [
      "account": .string("ac_missing00"), "capabilities": .array([.string("device")]),
    ]).status == .badRequest)
    #expect(try await postJSON(harness, "/v1/enroll", [
      "account": .string("ac_" + String(repeating: "z", count: 8)), "capabilities": .array([.string("device")]),
    ]).status == .notFound)
    #expect(try await postJSON(harness, "/v1/enroll", [
      "account": .string(account.id.rawValue), "capabilities": .array([]),
    ]).status == .badRequest)
    #expect(try await postJSON(harness, "/v1/enroll", [
      "account": .string(account.id.rawValue), "capabilities": .array([.string("root")]),
    ]).status == .badRequest)
    #expect(try await postJSON(harness, "/v1/enroll", [
      "account": .string(account.id.rawValue), "capabilities": .array([.string("device")]), "ttlSeconds": .integer(0),
    ]).status == .badRequest)
  }

  @Test func shareLoginMintsAOneTimeLinkForTheKeysAccount() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let key = Curve25519.Signing.PrivateKey()
    _ = try await harness.space.addKey(key.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)

    let minted = try await postJSON(harness, "/v1/enroll/share-login", try await signedShareLogin(harness, key: key))
    #expect(minted.status == .ok)
    let payload = try await json(minted)
    let token = try #require(payload.stringValue(at: "token"))
    #expect(expiresAtSeconds(payload) == fixedDate.timeIntervalSince1970 + 600)

    let consumed = try await postJSON(harness, "/v1/enroll/consume", [
      "token": .string(token), "pubkey": .string(testPubkey("phone")),
    ])
    #expect(consumed.status == .ok)
    let record = try #require(try await harness.space.credential(pubkey: testPubkey("phone")))
    #expect(record.account == account.id)
    #expect(record.capabilities == [.device])
    #expect(record.createdBy == account.id)

    let replay = try await postJSON(harness, "/v1/enroll/consume", [
      "token": .string(token), "pubkey": .string(testPubkey("replay")),
    ])
    #expect(replay.status == .unauthorized)
  }

  @Test func shareLoginHonorsARequestedTTLUpToTheCap() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let key = Curve25519.Signing.PrivateKey()
    _ = try await harness.space.addKey(key.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)

    let day = try await postJSON(harness, "/v1/enroll/share-login", try await signedShareLogin(harness, key: key, ttl: 86400))
    #expect(day.status == .ok)
    #expect(expiresAtSeconds(try await json(day)) == fixedDate.timeIntervalSince1970 + 86400)

    let cap = try await postJSON(harness, "/v1/enroll/share-login", try await signedShareLogin(harness, key: key, ttl: 259_200))
    #expect(cap.status == .ok)
    #expect(expiresAtSeconds(try await json(cap)) == fixedDate.timeIntervalSince1970 + 259_200)
  }

  @Test(arguments: [0, -60, 259_201])
  func shareLoginRejectsANonpositiveOrOverCapTTL(_ ttl: Int) async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let key = Curve25519.Signing.PrivateKey()
    _ = try await harness.space.addKey(key.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)

    let response = try await postJSON(harness, "/v1/enroll/share-login", try await signedShareLogin(harness, key: key, ttl: ttl))
    #expect(response.status == .badRequest)
    #expect((try await json(response)).stringValue(at: "code") == "invalidArgument")
    #expect(try await harness.space.credential(pubkey: testPubkey("phone")) == nil)
  }

  @Test func namingAPubkeyWithoutItsPrivateKeyCannotShareLogin() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let victim = Curve25519.Signing.PrivateKey()
    _ = try await harness.space.addKey(victim.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)

    let attacker = Curve25519.Signing.PrivateKey()
    let challenge = try await shareLoginChallenge(harness)
    let forged = try await postJSON(harness, "/v1/enroll/share-login", try shareLoginBody(
      pubkey: victim.pubkeyLabel, challenge: challenge, signedBy: attacker,
    ))
    #expect(forged.status == .unauthorized)

    let garbage = try await postJSON(harness, "/v1/enroll/share-login", .object([
      "pubkey": .string(victim.pubkeyLabel),
      "challenge": .string(try await shareLoginChallenge(harness)),
      "signature": .string("not-a-signature"),
    ]))
    #expect(garbage.status == .unauthorized)
  }

  @Test func aShareLoginChallengeIsOneShotAndMustComeFromTheServer() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let key = Curve25519.Signing.PrivateKey()
    _ = try await harness.space.addKey(key.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)

    #expect(try await postJSON(harness, "/v1/enroll/share-login", try shareLoginBody(
      pubkey: key.pubkeyLabel, challenge: "slc_selfinvented", signedBy: key,
    )).status == .unauthorized)

    let challenge = try await shareLoginChallenge(harness)
    let body = try shareLoginBody(pubkey: key.pubkeyLabel, challenge: challenge, signedBy: key)
    #expect(try await postJSON(harness, "/v1/enroll/share-login", body).status == .ok)
    #expect(try await postJSON(harness, "/v1/enroll/share-login", body).status == .unauthorized)
  }

  @Test func aP256KeyShareLoginsWithARawECDSASignature() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let key = P256.Signing.PrivateKey()
    _ = try await harness.space.addKey(key.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)

    let challenge = try await shareLoginChallenge(harness)
    let message = Data(ShareLogin.signingMessage(challenge: challenge).utf8)
    let minted = try await postJSON(harness, "/v1/enroll/share-login", .object([
      "pubkey": .string(key.pubkeyLabel),
      "challenge": .string(challenge),
      "signature": .string(try key.signature(for: message).rawRepresentation.base64EncodedString()),
    ]))
    #expect(minted.status == .ok)
  }

  @Test func aCrossCurveShareLoginSignatureIsRejected() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let p256 = P256.Signing.PrivateKey()
    let ed25519 = Curve25519.Signing.PrivateKey()
    _ = try await harness.space.addKey(p256.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    _ = try await harness.space.addKey(ed25519.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)

    let first = try await shareLoginChallenge(harness)
    let underP256Label = try await postJSON(harness, "/v1/enroll/share-login", .object([
      "pubkey": .string(p256.pubkeyLabel),
      "challenge": .string(first),
      "signature": .string(try ed25519.signature(for: Data(ShareLogin.signingMessage(challenge: first).utf8)).base64EncodedString()),
    ]))
    #expect(underP256Label.status == .unauthorized)

    let second = try await shareLoginChallenge(harness)
    let underEd25519Label = try await postJSON(harness, "/v1/enroll/share-login", .object([
      "pubkey": .string(ed25519.pubkeyLabel),
      "challenge": .string(second),
      "signature": .string(try p256.signature(for: Data(ShareLogin.signingMessage(challenge: second).utf8)).rawRepresentation.base64EncodedString()),
    ]))
    #expect(underEd25519Label.status == .unauthorized)
  }

  @Test func retiredKeyCannotShareLogin() async throws {
    let harness = try Harness()
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let key = Curve25519.Signing.PrivateKey()
    _ = try await harness.space.addKey(key.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    try await harness.space.removeKey(pubkey: key.pubkeyLabel)
    let response = try await postJSON(harness, "/v1/enroll/share-login", try await signedShareLogin(harness, key: key))
    #expect(response.status == .unauthorized)
  }

  @Test func theWallBlocksMintButShareLoginSelfAuthenticates() async throws {
    let harness = try Harness(dev: false)
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    let minted = try await harness.space.mintJoinToken(account: account.id, capabilities: [.device], createdBy: nil, lifetime: 600)

    #expect(try await postJSON(harness, "/v1/enroll", [
      "account": .string(account.id.rawValue), "capabilities": .array([.string("device")]),
    ]).status == .unauthorized)

    let consumed = try await postJSON(harness, "/v1/enroll/consume", [
      "token": .string(minted.token.rawValue), "pubkey": .string(testPubkey("phone")),
    ])
    #expect(consumed.status == .ok)
    #expect(try await harness.space.credential(pubkey: testPubkey("phone"))?.account == account.id)

    let key = Curve25519.Signing.PrivateKey()
    _ = try await harness.space.addKey(key.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    let shared = try await postJSON(harness, "/v1/enroll/share-login", try await signedShareLogin(harness, key: key))
    #expect(shared.status == .ok)
  }
}

private func expiresAtSeconds(_ payload: JSONValue) -> Double? {
  switch payload["expiresAt"] {
  case let .number(value): value
  case let .integer(value): Double(value)
  default: nil
  }
}

private func shareLoginChallenge(_ harness: Harness) async throws -> String {
  let response = try await harness.get(harness.api, "/v1/enroll/share-login/challenge")
  #expect(response.status == .ok)
  return try #require((try await json(response)).stringValue(at: "challenge"))
}

private func shareLoginBody(pubkey: String, challenge: String, signedBy key: Curve25519.Signing.PrivateKey, ttl: Int? = nil) throws -> JSONValue {
  let signature = try key.signature(for: Data(ShareLogin.signingMessage(challenge: challenge).utf8)).base64EncodedString()
  if let ttl {
    return .object([
      "pubkey": .string(pubkey),
      "challenge": .string(challenge),
      "signature": .string(signature),
      "ttlSeconds": .integer(ttl),
    ])
  }
  return .object([
    "pubkey": .string(pubkey),
    "challenge": .string(challenge),
    "signature": .string(signature),
  ])
}

private func signedShareLogin(_ harness: Harness, key: Curve25519.Signing.PrivateKey, ttl: Int? = nil) async throws -> JSONValue {
  try shareLoginBody(pubkey: key.pubkeyLabel, challenge: try await shareLoginChallenge(harness), signedBy: key, ttl: ttl)
}

private func postJSON(_ harness: Harness, _ path: String, _ body: JSONValue) async throws -> Response {
  try await harness.api(Request(
    url: URL(string: "http://space\(path)")!,
    method: .post,
    body: .bytes(Data(body.jsonString().utf8), contentType: "application/json"),
  ))
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
}
