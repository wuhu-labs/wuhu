import struct SpaceClient.SpaceClient
import struct SpaceContract.PersonaMintOutput

extension Executor {
  mutating func announceWallet(client: SpaceClient, signed: Bool) async throws {
    guard self.walletAnnouncementPending else { return }
    self.walletAnnouncementPending = false
    let label = try await askPersona(client, signed: signed) ?? "anonymous"
    await self.runner.stderr("acting as \(label) (wallet)\n")
  }

  mutating func finishWalletAnnouncement() async {
    guard self.walletAnnouncementPending else { return }
    self.walletAnnouncementPending = false
    await self.runner.stderr("acting as the local user (wallet)\n")
  }

  mutating func persona(space: String) async throws -> String? {
    let signed = try await self.bearerSource(space: space) != nil
    return try await askPersona(self.authenticated(space), signed: signed)
  }
}

// Asked of the server every time, never cached: a revoked or re-enrolled
// device key must not keep claiming the persona it used to have. Unsigned,
// the server either seats a person or refuses, and a refusal is no identity.
private func askPersona(_ client: SpaceClient, signed: Bool) async throws -> String? {
  do {
    let output: PersonaMintOutput = try await client.api(.post, "/v1/persona")
    return output.persona
  } catch let failure as SpaceClient.ToolFailure where !signed && failure.error.code == .unauthorized {
    return nil
  }
}
