import LoopCore
import class MainHub.Hub
import SessionTools
@testable import SpaceServer

// The loop worker with main bound in process, as the kernel wires it.
func firingWorker(_ owner: Hub) async -> SessionExecution {
  let tokens = ExecTokens(spaceURL: "http://main")
  let connection = MainConnection()
  let worker = await SessionExecution(main: owner, connection: connection, credential: { tokens.sessionToken($0) }) { tools in
    LoopConfig(
      executeTool: { try await tools.execute(session: $0.sessionID, call: $0.call, state: $0.state) },
      inference: { _ in throw Mismatch("unexpected inference in subscription test") },
      compact: { _, _ in throw Mismatch("unexpected compaction in subscription test") },
      budget: { _ in .init(maxInput: 100_000, maxOutput: 1000) },
    )
  }
  SessionRuntime.bindMain(owner: owner, worker: worker, tokens: tokens, connection: connection)
  return worker
}
