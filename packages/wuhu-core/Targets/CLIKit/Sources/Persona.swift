import struct SpaceClient.SpaceClient
import struct SpaceContract.PersonaMintOutput

extension Executor {
  mutating func announceWallet(client: SpaceClient, hasBearer: Bool) async throws {
    guard self.walletAnnouncementPending else { return }
    self.walletAnnouncementPending = false
    let label = hasBearer ? try await mintPersona(client) : "anonymous"
    await self.runner.stderr("acting as \(label) (wallet)\n")
  }

  mutating func finishWalletAnnouncement() async {
    guard self.walletAnnouncementPending else { return }
    self.walletAnnouncementPending = false
    await self.runner.stderr("acting as the local user (wallet)\n")
  }

  mutating func persona(space: String) async throws -> String? {
    guard try await self.bearerSource(space: space) != nil else { return nil }
    return try await mintPersona(self.authenticated(space))
  }
}

// Asked of the server every time, never cached: a revoked or re-enrolled
// device key must not keep claiming the persona it used to have.
private func mintPersona(_ client: SpaceClient) async throws -> String {
  let output: PersonaMintOutput = try await client.api(.post, "/v1/persona")
  return output.persona
}
