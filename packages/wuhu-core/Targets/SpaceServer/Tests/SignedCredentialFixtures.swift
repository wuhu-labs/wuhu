#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct Credentials.SpaceSecretStores
import Fetch
import InferenceKit
import LoopCore
import MachineContract
import class MainHub.Hub
import SessionDomain
import SessionTools
import SpaceCore
@testable import SpaceServer

func testTokens(space: Space, spaceURL: String = "http://main") async throws -> ExecTokens {
  let key = try ServerIdentity(rawKey: Data(repeating: 1, count: 32))
  let keys = MemoryFiles().identityKeys
  try await keys.store(key)
  var identity = IdentityController(space: space, origin: "https://space.test", keys: keys)
  if identity.state == nil {
    identity = IdentityController.configure(space: space, origin: "https://space.test", keys: keys, fetch: FetchClient { _ in Response(status: .forbidden) })
    try await identity.initialize(identity: key)
  }
  return ExecTokens(spaceURL: spaceURL, identity: identity)
}

struct SessionToolFixture: Sendable {
  let tokens: ExecTokens
  let connection: MainConnection
  let execution: SessionExecution

  init(space: Space, tokens suppliedTokens: ExecTokens? = nil, access: InferenceAccess = InferenceAccess()) async throws {
    let tokens: ExecTokens
    if let supplied = suppliedTokens {
      tokens = supplied
    } else {
      tokens = try await testTokens(space: space)
    }
    self.tokens = tokens
    let connection = MainConnection()
    self.connection = connection
    execution = SessionExecution(
      connection: connection, credential: { try await tokens.sessionToken($0) }, access: access, space: space,
      observerRun: { observer, _, body in
        let token = tokens.scriptToken(.observer(observer))
        defer { tokens.revokeScript(token) }
        return try await body(token)
      },
    ) { tools in
      LoopConfig(
        executeTool: { try await tools.execute(session: $0.sessionID, call: $0.call, state: $0.state) },
        inference: { _ in throw ToolFixtureInference() },
        budget: { _ in .init(maxInput: 100_000, maxOutput: 1000) },
        sources: .unavailable,
      )
    }
  }
}

private struct ToolFixtureInference: Error, CustomStringConvertible {
  var description: String { "unexpected inference in tool-only fixture" }
}

extension SessionRuntime {
  static func toolExecutor(
    owner: Hub, execution: SessionExecution, hub: MachineHub? = nil, access: InferenceAccess = InferenceAccess(),
    origin: String? = nil, contentHostPattern: String? = nil, secrets: SpaceSecretStores? = nil, identity: IdentityController? = nil,
  ) async throws -> ToolExecutor {
    let tokens = try await testTokens(space: owner.space)
    return toolExecutor(owner: owner, execution: execution, tokens: tokens, hub: hub, access: access, origin: origin, contentHostPattern: contentHostPattern, secrets: secrets, identity: identity)
  }
}

extension ExecTokens {
  func credential(session: SessionDomain.SessionID, exec: MachineContract.ExecID, timeout: Double?, now: Date) async throws -> MachineContract.ExecSessionCredential {
    let record = try await space.execRecord(exec)!
    let value = try await credential(session: session, group: record.group, machine: record.machine, exec: exec, timeout: .seconds(timeout ?? Self.longestLife), issuedAt: now)
    return .init(token: value.object!["token"]!.stringValue!, spaceURL: spaceURL)
  }
}
