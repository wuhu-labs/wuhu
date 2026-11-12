#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.SpaceSecretStores
import DeterministicDependencies
import Fetch
import InferenceKit
import MachineContract
import class MainHub.Hub
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer
import Testing

func testTokens(space: Space, spaceURL: String = "http://main") async throws -> ExecTokens {
  let key = try ServerIdentity(rawKey: Data(repeating: 1, count: 32))
  let keys = IdentityKeys(load: { kid in precondition(kid == key.kid); return key }, store: { stored in precondition(stored.kid == key.kid) })
  var identity = IdentityController(space: space, origin: "https://space.test", keys: keys)
  if identity.state == nil {
    identity = IdentityController.configure(space: space, origin: "https://space.test", keys: keys, fetch: FetchClient { _ in Response(status: .forbidden) })
    try await identity.initialize(identity: key)
  }
  return ExecTokens(spaceURL: spaceURL, identity: identity)
}

extension SessionRuntime {
  static func toolExecutor(
    owner: Hub, hub: MachineHub? = nil, access: InferenceAccess = InferenceAccess(),
    origin: String? = nil, contentHostPattern: String? = nil, secrets: SpaceSecretStores? = nil, identity: IdentityController? = nil,
  ) async throws -> ToolExecutor {
    let tokens = try await testTokens(space: owner.space)
    return toolExecutor(owner: owner, tokens: tokens, hub: hub, access: access, origin: origin, contentHostPattern: contentHostPattern, secrets: secrets, identity: identity)
  }
}

extension ExecTokens {
  func credential(session: SessionDomain.SessionID, exec: MachineContract.ExecID, timeout: Double?, now: Date) async throws -> MachineContract.ExecSessionCredential {
    let record = try await space.execRecord(exec)!
    let value = try await credential(session: session, group: record.group, machine: record.machine, exec: exec, timeout: .seconds(timeout ?? Self.longestLife), issuedAt: now)
    return .init(token: value.object!["token"]!.stringValue!, spaceURL: spaceURL)
  }
}

@Suite(.deterministicDependencies) struct SignedCredentialFixtureTests {
  @Test func aSuppliedFixtureKeyUsesTheExistingWorkersClock() async throws {
    let space = try Space.inMemory()
    let runtimeDate = Date(timeIntervalSince1970: Double(space.worker.scheduler.now.milliseconds) / 1000)
    try await withToolDeps { _ in
      let tokens = try await testTokens(space: space)
      let state = try #require(tokens.identity.state)
      #expect(state.schedule.rotatedAt == runtimeDate)
      #expect(state.pending == nil)
      #expect(!state.rotating)
    }
    try await space.close()
  }
}
