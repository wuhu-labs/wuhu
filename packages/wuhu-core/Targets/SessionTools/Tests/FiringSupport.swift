import LoopCore
import struct MainHub.EventSources
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

// The sessions' runtime with main bound in process, as the kernel wires it, started.
func firingWorker(_ owner: Hub, sources: EventSources = .unavailable) async -> SessionExecution {
  let tokens = ExecTokens(spaceURL: "http://main")
  let connection = MainConnection()
  let worker = SessionExecution(
    connection: connection,
    credential: { tokens.sessionToken($0) },
    space: owner.space,
    observerRun: { observer, _, body in
      let token = tokens.scriptToken(.observer(observer))
      defer { tokens.revokeScript(token) }
      return try await body(token)
    },
  ) { tools in
    LoopConfig(
      executeTool: { try await tools.execute(session: $0.sessionID, call: $0.call, state: $0.state) },
      inference: { _ in throw Mismatch("unexpected inference in a firing test: hold the session so its cell leaves its queue alone") },
      compact: { _, _ in throw Mismatch("unexpected compaction in subscription test") },
      budget: { _ in .init(maxInput: 100_000, maxOutput: 1000) },
      sources: sources,
    )
  }
  SessionRuntime.bindMain(owner: owner, execution: worker, tokens: tokens, connection: connection)
  worker.start()
  return worker
}
