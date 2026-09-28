import struct SpaceClient.SpaceClient
import struct SpaceContract.PersonaMintOutput

extension Executor {
  // The persona is a server-side allocator draw recorded against this
  // device's enrolled key; the wallet only caches it. bearerSource returns
  // non-nil whenever a local key merely exists, so the server is the only
  // authority on whether that key is still enrolled: a rejected mint (a key
  // the space kicked, or a folder whose space.sqlite was reset while the key
  // survived) is indistinguishable from having no key, and degrades to the
  // same owner attribution rather than crashing every identity verb. Any
  // other failure — an unreachable server, a malformed response — still
  // throws, so a broken setup is not silently masked as the owner.
  mutating func persona(space: String) async throws -> String? {
    // A session speaks as itself; the server takes that from its token.
    guard self.session == nil else { return nil }
    if let cached = try self.wallet.persona(space: space) { return cached }
    guard try await self.bearerSource(space: space) != nil else { return nil }
    let output: PersonaMintOutput
    do {
      output = try await self.authenticated(space).api(.post, "/v1/persona")
    } catch let failure as SpaceClient.ToolFailure where failure.error.code == .unauthorized {
      return nil
    }
    try self.wallet.recordPersona(output.persona, space: space)
    return output.persona
  }
}
