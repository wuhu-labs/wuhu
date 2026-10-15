import Crypto
import Fetch
import Foundation
import GRDB
import JSONValue
import MachineContract
import OperationProtocol
import Serve
@testable import SpaceCore
@testable import SpaceServer
import Testing

extension MachineV2TunnelTests {
  private func verdict(_ result: UpgradeResult) async throws -> (Status, String?) {
    guard case let .response(response) = result else { return (.ok, nil) }
    let body = try await response.body.json(JSONValue.self).object
    return (response.status, body?["code"]?.stringValue ?? body?["error"]?.object?["code"]?.stringValue)
  }

  /// Signed status, connect and revoke, each with a challenge minted before `between` runs.
  private func probes(_ f: Fixture, key: Curve25519.Signing.PrivateKey, between: () async throws -> Void = {}) async throws -> [(Status, String?)] {
    let id = f.machine.id
    let status = try await signed(f.handler, "/v1/machine-v2/\(id.rawValue)", method: .get, key: key, machine: id)
    let challenge = try await f.challenge()
    let revoke = try await signed(f.handler, "/v1/machine-v2/\(id.rawValue)/revoke", key: key, machine: id)
    try await between()
    return [
      try await verdict(try await f.handler(status)),
      try await verdict(try await f.connect(challenge, machines: [id.rawValue])),
      try await verdict(try await f.handler(revoke)),
    ]
  }

  @Test func anAuthorizationOutageIsRetryableNeverAKeyVerdict() async throws {
    let f = try await Fixture()
    let offline = { try await f.space.writer.write { db in try db.execute(sql: "ALTER TABLE account_keys RENAME TO account_keys_offline") } }
    for (status, code) in try await probes(f, key: f.key, between: offline) {
      #expect(status == .serviceUnavailable)
      #expect(code == "machineAuthUnavailable")
    }
    try await f.space.writer.write { db in try db.execute(sql: "ALTER TABLE account_keys_offline RENAME TO account_keys") }
    #expect(try await f.space.machine(pubkey: f.key.pubkeyLabel) == f.machine.id)

    let outage = try await probes(f, key: f.key) { await f.hub.fail(OperationError(.storeUnavailable)) }
    #expect(outage.allSatisfy { $0.0 == .serviceUnavailable })
    #expect(try await f.space.machine(pubkey: f.key.pubkeyLabel) == f.machine.id)
  }

  @Test func aRevokedKeyIsADefinitiveRefusalOnEveryPath() async throws {
    let f = try await Fixture()
    _ = try await f.space.resetCredentials(account: f.machine.account)
    for (status, code) in try await probes(f, key: f.key) {
      #expect(status == .unauthorized)
      #expect(code == "machineNotAuthorized")
    }
  }
}
