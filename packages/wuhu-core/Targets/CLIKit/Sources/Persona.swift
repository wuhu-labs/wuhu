import struct SpaceClient.SpaceClient
import struct SpaceContract.PersonaMintOutput

extension Executor {
  mutating func announceWallet(space: String, client: SpaceClient, hasBearer: Bool) async throws {
    guard self.walletAnnouncementPending else { return }
    self.walletAnnouncementPending = false
    let label = hasBearer ? try await self.walletPersona(space: space, client: client) : "anonymous"
    await self.runner.stderr("acting as \(label) (wallet)\n")
  }

  mutating func finishWalletAnnouncement() async {
    guard self.walletAnnouncementPending else { return }
    self.walletAnnouncementPending = false
    await self.runner.stderr("acting as the local user (wallet)\n")
  }

  // Existing identity verbs tolerate a revoked device key; a wallet opt-in
  // must surface that rejection before announcing who it acts as.
  mutating func persona(space: String) async throws -> String? {
    guard self.session == nil else { return nil }
    if let cached = try self.wallet.persona(space: space) { return cached }
    guard try await self.bearerSource(space: space) != nil else { return nil }
    do {
      let client = try await self.authenticated(space)
      return try await self.walletPersona(space: space, client: client)
    } catch let failure as SpaceClient.ToolFailure where !self.walletOptIn && failure.error.code == .unauthorized {
      return nil
    }
  }

  private mutating func walletPersona(space: String, client: SpaceClient) async throws -> String {
    if let cached = try self.wallet.persona(space: space) { return cached }
    let output: PersonaMintOutput = try await client.api(.post, "/v1/persona")
    try self.wallet.recordPersona(output.persona, space: space)
    return output.persona
  }
}
