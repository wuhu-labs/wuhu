import Assertion
import Crypto
import Fetch
import Foundation
import JSONValue
import SpaceContract
import SpaceCore
import Testing

@Suite struct PersonaRoutesTests {
  let harness: Harness
  let identity: String
  let key = Curve25519.Signing.PrivateKey()

  init() async throws {
    harness = try Harness(dev: false)
    identity = try await harness.space.identity().rawValue
  }

  func enroll(capabilities: Set<KeyCapability> = [.device]) async throws -> KeyRecord {
    let account = try await harness.space.addAccount(kind: .human, name: nil)
    return try await harness.space.addKey(
      key.pubkeyLabel, account: account.id, capabilities: capabilities, createdBy: nil, expiresAt: nil,
    )
  }

  func mintRequest(bearer: String?) async throws -> Response {
    var request = Request(url: URL(string: "http://space/v1/persona")!, method: .post)
    if let bearer {
      request.headers[.authorization] = "Bearer " + bearer
    }
    return try await harness.api(request)
  }

  func assertion() throws -> String {
    try AssertionClaims(key: key.pubkeyLabel, space: identity, expiresAt: fixedDate.addingTimeInterval(3600))
      .signed(by: key).rawValue
  }

  @Test func mintingAdoptsTheAccountsPersonaAndTracesToTheKey() async throws {
    let enrolled = try await enroll()
    let first = try JSONValueDecoder().decode(
      PersonaMintOutput.self, from: try await json(try await mintRequest(bearer: try assertion())),
    )
    let second = try JSONValueDecoder().decode(
      PersonaMintOutput.self, from: try await json(try await mintRequest(bearer: try assertion())),
    )
    #expect(first.persona == second.persona)
    #expect(first.persona.split(separator: "-").count >= 3)
    let record = try #require(try await harness.space.persona(named: first.persona))
    #expect(record.key == enrolled.pubkey)
    #expect(record.account == enrolled.account)
  }

  @Test func anonymousMintingIsRefused() async throws {
    let response = try await mintRequest(bearer: nil)
    #expect(response.status == .unauthorized)
  }

  @Test func aMachineOnlyKeyCannotMintAPersona() async throws {
    _ = try await enroll(capabilities: [.execMachine])
    let response = try await mintRequest(bearer: try assertion())
    #expect(response.status == .unauthorized)
  }
}
