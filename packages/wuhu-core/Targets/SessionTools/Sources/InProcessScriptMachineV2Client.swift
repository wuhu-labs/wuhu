import class OperationClient.OperationClient
import struct SpaceContract.GroupID

public extension ScriptMachineV2Client {
  init(client: OperationClient) {
    self.init(
      describe: { try await client.describe($0) },
      start: { try await client.start($0, request: $1, owner: $2, timeout: $3, onClaim: $4) },
      reconcile: { try await client.reconcile($0, holdMs: $1) },
      poll: { try await client.poll($0, channel: $1, holdMs: $2, terminalAck: $3) },
      takeOutput: { try await client.takeOutput($0, channel: $1) },
      write: { try await client.write($0, channel: $1, payload: $2, end: $3) },
      stop: { try await client.stop($0, reason: $1) },
    )
  }
}

public extension ScriptMachineV2Access {
  init(client: @escaping @Sendable (GroupID) async throws -> OperationClient) {
    self.init(client: { try await ScriptMachineV2Client(client: client($0)) })
  }
}
