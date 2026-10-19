import LoopCore
import class MainHub.Hub

func firingWorker(_ owner: Hub) async -> SessionExecution {
  await SessionExecution(main: owner) { tools in
    LoopConfig(
      executeTool: { try await tools.execute(session: $0.sessionID, call: $0.call, state: $0.state) },
      inference: { _ in throw Mismatch("unexpected inference in subscription test") },
      compact: { _, _ in throw Mismatch("unexpected compaction in subscription test") },
      budget: { _ in .init(maxInput: 100_000, maxOutput: 1000) },
    )
  }
}
