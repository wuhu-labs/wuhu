import Assertion
import Crypto
import Fetch
import Foundation
import JSONValue
import SpaceContract
import SpaceCore
import SpaceServer
import Testing

@Suite struct AssertionGateTests {
  let harness: Harness
  let identity: String
  let key = Curve25519.Signing.PrivateKey()

  init() async throws {
    harness = try Harness(dev: false)
    identity = try await harness.space.identity().rawValue
  }

  func enroll(
    _ pubkey: String,
    in space: Space,
    capabilities: Set<KeyCapability> = [.device],
    expiresAt: Date? = nil,
  ) async throws {
    let account = try await space.addAccount(kind: .human, name: nil)
    _ = try await space.addKey(pubkey, account: account.id, capabilities: capabilities, createdBy: nil, expiresAt: expiresAt)
  }

  func mint(
    key: Curve25519.Signing.PrivateKey? = nil,
    space: String? = nil,
    expiresAt: Date = fixedDate.addingTimeInterval(3600),
  ) throws -> String {
    let key = key ?? self.key
    return try AssertionClaims(key: key.pubkeyLabel, space: space ?? identity, expiresAt: expiresAt)
      .signed(by: key).rawValue
  }

  func request(bearer: String?, scheme: String = "Bearer") async throws -> Response {
    var request = Request(url: URL(string: "http://space/v1/machine")!)
    if let bearer {
      request.headers[.authorization] = scheme + " " + bearer
    }
    return try await harness.api(request)
  }

  func message(_ response: Response) async throws -> String {
    let error = try JSONValueDecoder().decode(ToolError.self, from: try await json(response))
    #expect(error.code == .unauthorized)
    return error.message + (error.hint.map { "\n" + $0 } ?? "")
  }

  @Test func aVerifiedAssertionOpensTheWall() async throws {
    try await enroll(key.pubkeyLabel, in: harness.space)
    let response = try await request(bearer: try mint())
    #expect(response.status == .ok)
  }

  @Test func aP256AssertionOpensTheWall() async throws {
    let p256 = P256.Signing.PrivateKey()
    try await enroll(p256.pubkeyLabel, in: harness.space)
    let assertion = try AssertionClaims(
      key: p256.pubkeyLabel,
      space: identity,
      expiresAt: fixedDate.addingTimeInterval(3600),
    ).signed(by: p256)
    #expect(try await request(bearer: assertion.rawValue).status == .ok)
  }

  @Test func anEdDSAAssertionNamingAP256KeyRowIsRejected() async throws {
    let p256 = P256.Signing.PrivateKey()
    try await enroll(p256.pubkeyLabel, in: harness.space)
    // A genuine Ed25519 signature with an EdDSA header, but the named key row
    // is p256: the alg<->key binding must refuse it at the gate.
    let confused = try AssertionClaims(
      key: p256.pubkeyLabel,
      space: identity,
      expiresAt: fixedDate.addingTimeInterval(3600),
    ).signed(by: key)
    #expect(try await request(bearer: confused.rawValue).status == .unauthorized)
  }

  @Test func everyUserCapableKeyOpensTheWall() async throws {
    for capabilities: Set<KeyCapability> in [[.device], [.seat], [.contractor], [.execMachine, .device]] {
      let key = Curve25519.Signing.PrivateKey()
      try await enroll(key.pubkeyLabel, in: harness.space, capabilities: capabilities)
      #expect(try await request(bearer: try mint(key: key)).status == .ok)
    }
  }

  @Test func aMachineOrSpaceOnlyKeyCannotActAsAUser() async throws {
    for capabilities: Set<KeyCapability> in [[.execMachine], [.space]] {
      let key = Curve25519.Signing.PrivateKey()
      try await enroll(key.pubkeyLabel, in: harness.space, capabilities: capabilities)
      let response = try await request(bearer: try mint(key: key))
      #expect(response.status == .unauthorized)
      let text = try await message(response)

      // Byte-identical to a never-enrolled key: the response reveals neither
      // that the pubkey exists nor what capabilities it holds.
      let ghost = try await request(bearer: try mint(key: Curve25519.Signing.PrivateKey()))
      #expect(ghost.status == .unauthorized)
      #expect(text == (try await message(ghost)))

      // Same claims shape and a genuine signature succeed once the key is
      // user-capable, so the rejection above is the capability gate alone.
      let control = Curve25519.Signing.PrivateKey()
      try await enroll(control.pubkeyLabel, in: harness.space, capabilities: capabilities.union([.device]))
      #expect(try await request(bearer: try mint(key: control)).status == .ok)
    }
  }

  @Test func aKickedKeyDiesAtItsNextRequest() async throws {
    try await enroll(key.pubkeyLabel, in: harness.space)
    let assertion = try mint()
    #expect(try await request(bearer: assertion).status == .ok)
    try await harness.space.removeKey(pubkey: key.pubkeyLabel)
    let kicked = try await request(bearer: assertion)
    #expect(kicked.status == .unauthorized)
    let text = try await message(kicked)
    #expect(text.contains("revoked"))
    #expect(text.contains("wuhu login"))
  }

  @Test func deleteKeyIsSelfRevocation() async throws {
    try await enroll(key.pubkeyLabel, in: harness.space)
    let assertion = try mint()
    var revoke = Request(url: URL(string: "http://space/v1/key")!, method: .delete)
    revoke.headers[.authorization] = "Bearer " + assertion
    #expect(try await harness.api(revoke).status == .noContent)
    #expect(try await harness.space.credential(pubkey: key.pubkeyLabel) == nil)
    #expect(try await harness.api(revoke).status == .unauthorized)
  }

  @Test func anExpiredKeyRowIsAsDeadAsAKickedOne() async throws {
    try await enroll(key.pubkeyLabel, in: harness.space, expiresAt: fixedDate.addingTimeInterval(-1))
    let response = try await request(bearer: try mint())
    #expect(response.status == .unauthorized)
    #expect(try await message(response).contains("revoked"))
  }

  @Test func anAssertionForSpaceAIsRejectedBySpaceB() async throws {
    // Even with the very same key enrolled on both sides, the space claim
    // alone must pin the assertion to the space it was minted for.
    let other = try Harness(dev: false)
    let otherIdentity = try await other.space.identity().rawValue
    #expect(identity != otherIdentity)
    try await enroll(key.pubkeyLabel, in: other.space)
    var request = Request(url: URL(string: "http://space/v1/machine")!)
    request.headers[.authorization] = "Bearer " + (try mint(space: identity))
    let response = try await other.api(request)
    #expect(response.status == .unauthorized)
    let error = try JSONValueDecoder().decode(ToolError.self, from: try await json(response))
    #expect(error.message.contains(identity))
    #expect(error.message.contains(otherIdentity))
  }

  @Test func anExpiredAssertionIsRejectedAtTheBoundary() async throws {
    try await enroll(key.pubkeyLabel, in: harness.space)
    let expired = try await request(bearer: try mint(expiresAt: fixedDate))
    #expect(expired.status == .unauthorized)
    #expect(try await message(expired).contains("expired"))
    let live = try await request(bearer: try mint(expiresAt: fixedDate.addingTimeInterval(1)))
    #expect(live.status == .ok)
  }

  @Test func aForeignSignatureIsRejected() async throws {
    try await enroll(key.pubkeyLabel, in: harness.space)
    let forged = try AssertionClaims(
      key: key.pubkeyLabel, space: identity,
      expiresAt: fixedDate.addingTimeInterval(3600),
    ).signed(by: Curve25519.Signing.PrivateKey()).rawValue
    let response = try await request(bearer: forged)
    #expect(response.status == .unauthorized)
    #expect(try await message(response).contains("signature"))
  }

  @Test func aJunkPubkeyCanNoLongerBeEnrolled() async throws {
    await #expect(throws: SpaceError.malformedPubkey("ed25519:phone")) {
      try await enroll("ed25519:phone", in: harness.space)
    }
  }

  @Test func malformedAndMisSchemedCredentialsAreRejected() async throws {
    try await enroll(key.pubkeyLabel, in: harness.space)
    #expect(try await request(bearer: "not-an-assertion").status == .unauthorized)
    #expect(try await request(bearer: try mint(), scheme: "Basic").status == .unauthorized)
  }
}
