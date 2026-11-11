import InferenceKit
import Logging
import LoopCore
import struct MainHub.EventSources
import SessionDomain
import SessionTools
import SpaceCore

/// The sessions' runtime as the kernel wires it: the loops with the real inference, the tools and the scripts. Its tools reach main's API through `connection` as the session, with the session's token from `tokens`. `usage` is where its inferences report the providers' plan usage; `machines` is where an archived session's execs and an observer firing's processes are ended.
struct KernelWorker: Sendable {
  let execution: SessionExecution
  /// The provider sockets its inferences hold open; `run` keeps them.
  let sockets: ResponsesSocketRegistry

  init(
    connection: MainConnection, tokens: ExecTokens, machines: MachineHub?, access: InferenceAccess, usage: UsageBoard,
    thresholds: CompactionThresholds = CompactionThresholds(), sources: EventSources = .unavailable, space: Space, scripts: Scripts? = nil,
  ) {
    let store = space.sessions
    let sockets = ResponsesSocketRegistry()
    self.sockets = sockets
    execution = SessionExecution(
      connection: connection, credential: { tokens.sessionToken($0) }, access: access, space: space, scripts: scripts,
      archived: { session in
        if let machines {
          do {
            for record in try await space.liveToolExecs(caller: session.rawValue) {
              do { try await machines.kill(record.id) }
              catch { Logger(label: "wuhu.exec").error("could not kill archived session's exec: \(error)") }
            }
          } catch { Logger(label: "wuhu.exec").error("could not read archived session's live execs: \(error)") }
        }
        tokens.revokeSession(session)
      },
      observerRun: { observer, script, body in
        try await tokens.runSessionless(.observer(observer), script: script, machines: machines, body)
      },
    ) { executor in
      let budget = budgetResolver(store: store, executor: executor)
      return LoopConfig(
        executeTool: { invocation in
          try await executor.execute(session: invocation.sessionID, call: invocation.call, state: invocation.state, yielded: invocation.yielded)
        },
        inference: kernelInference(
          store: store, executor: executor, access: access, sockets: sockets,
          usage: usage,
          committedWarming: { id, policy in
            do { try await store.scheduleCacheWarming(id, intervalSeconds: policy.intervalSeconds) }
            catch { Logger(label: "wuhu.cache-warmer").error("could not schedule cache warming", metadata: ["session": "\(id.rawValue)", "error": "\(error)"]) }
          },
        ),
        budget: budget,
        prepareCompaction: compactionPlacement(store: store, catalog: { try await executor.catalog($0, includeGroups: true) }, usage: usage),
        killInterruptedTool: { invocation in
          guard invocation.call.name == "exec" else { return }
          await executor.killInterrupted(session: invocation.sessionID, callID: ToolCallID(invocation.call.id))
        },
        invalidateInference: { await sockets.invalidate($0) },
        thresholds: thresholds,
        sources: sources,
        turnDifference: access.lineDifferences.map { log in { @Sendable difference in await log.record(difference) } },
      )
    }
  }
}
