#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import MachineContract
import SessionDomain
import SpaceCore
@testable import SpaceServer
import Synchronization

func testTokens(space: Space, spaceURL: String = "http://main") async throws -> ExecTokens {
  let key = try ServerIdentity(rawKey: Data(repeating: 1, count: 32))
  let stored = Mutex([key.kid: key])
  let keys = IdentityKeys(load: { kid in stored.withLock { $0[kid]! } }, store: { key in stored.withLock { $0[key.kid] = key } })
  var identity = IdentityController(space: space, origin: "https://space.test", keys: keys)
  if identity.state == nil {
    identity = IdentityController.configure(space: space, origin: "https://space.test", keys: keys, fetch: FetchClient { _ in Response(status: .forbidden) })
    try await identity.initialize(identity: key)
  }
  return ExecTokens(spaceURL: spaceURL, identity: identity)
}

extension ExecTokens {
  func credential(session: SessionDomain.SessionID, exec: MachineContract.ExecID, timeout: Double?, now: Date) async throws -> MachineContract.ExecSessionCredential {
    let record = try await space.execRecord(exec)!
    let value = try await credential(session: session, group: record.group, machine: record.machine, exec: exec, timeout: .seconds(timeout ?? Self.longestLife), issuedAt: now)
    return .init(token: value.object!["token"]!.stringValue!, spaceURL: spaceURL)
  }
}
