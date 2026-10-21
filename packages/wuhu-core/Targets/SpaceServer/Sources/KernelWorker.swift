import InferenceKit
import Logging
import LoopCore
import protocol MainHub.Main
import SessionDomain
import SessionTools

/// A worker as the kernel wires it: the loops with the real inference, the
/// tools and the scripts. Everything it reaches of main goes through
/// `connection` with the worker's `credential`; it holds nothing of main's.
/// `attempts` and `usage` are where its inferences report their streams and
/// the providers' plan usage.
struct KernelWorker: Sendable {
  let execution: SessionExecution
  /// The provider sockets its inferences hold open; `run` keeps them.
  let sockets: ResponsesSocketRegistry

  init(
    connection: MainConnection, credential: String, access: InferenceAccess, attempts: AttemptHub, usage: UsageBoard,
    thresholds: CompactionThresholds = CompactionThresholds(),
  ) async {
    let main = MainClient(connection: connection, credential: { credential })
    let sockets = ResponsesSocketRegistry()
    self.sockets = sockets
    execution = await SessionExecution(
      main: main, connection: connection, credential: { try await main.sessionToken($0) }, access: access,
    ) { executor in
      let budget = budgetResolver(owner: main, executor: executor)
      var config = LoopConfig(
        executeTool: { invocation in
          try await executor.execute(session: invocation.sessionID, call: invocation.call, state: invocation.state)
        },
        inference: kernelInference(
          owner: main, executor: executor, access: access, sockets: sockets, attempts: attempts,
          usage: usage,
          committedWarming: { id, policy in
            do { try await main.scheduleCacheWarming(id, intervalSeconds: policy.intervalSeconds) }
            catch { Logger(label: "wuhu.cache-warmer").error("could not schedule cache warming", metadata: ["session": "\(id.rawValue)", "error": "\(error)"]) }
          },
        ),
        compact: { id, transcript in
          await mechanicalCompaction(of: transcript, images: budget(id).images)
        },
        budget: budget,
        prepareCompaction: compactionPlacement(owner: main, catalog: { try await executor.catalog($0, includeGroups: true) }, usage: usage),
        killInterruptedTool: { invocation in
          guard invocation.call.name == "exec" else { return }
          await executor.killInterrupted(session: invocation.sessionID, callID: ToolCallID(invocation.call.id))
        },
        releaseTool: { invocation in
          await executor.release(session: invocation.sessionID, callID: ToolCallID(invocation.call.id))
        },
        invalidateInference: { await sockets.invalidate($0) },
        allowCacheWarming: { try await main.allowsCacheWarming($0) },
        thresholds: thresholds,
      )
      config.scheduleWake = { session, due in try await main.scheduleWake(session, at: due) }
      return config
    }
  }
}
