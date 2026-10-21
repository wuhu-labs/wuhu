import LoopCore
import class MainHub.Hub
import SessionTools
@testable import SpaceServer

// Parks until the task is cancelled, then runs `then`: what a test's worker
// or scripts do when its task group ends.
func whenCancelled(_ then: @Sendable () async -> Void) async {
  let (parked, end) = AsyncStream<Void>.makeStream()
  for await _ in parked {}
  end.finish()
  await then()
}

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
  let workers = WorkerRegistry(tokens: tokens)
  workers.announce(workers.mint().id, endpoint: worker)
  SessionRuntime.bindMain(owner: owner, workers: workers, tokens: tokens, connection: connection)
  return worker
}
