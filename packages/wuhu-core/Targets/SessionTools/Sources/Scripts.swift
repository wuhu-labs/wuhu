#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dependencies
import struct MainHub.ScriptRun
import enum MainHub.ToolLifetimes
import struct MainHub.ToolProblem
import ServerTelemetry
import SessionDomain
import enum SpaceContract.ScriptOutput
import TaskLifetime

public final class Scripts: Sendable {
  let limits: ScriptLimits
  private let scope = TaskScope()

  public convenience init() { self.init(limits: .standard) }

  init(limits: ScriptLimits) { self.limits = limits }

  deinit { scope.cancel() }

  public func close() async {
    scope.cancel()
    await scope.close()
  }

  public func run(_ script: ScriptRun, tools: ToolExecutor, output: @escaping @Sendable (ScriptOutput) -> Void) async throws {
    let (id, actor, root): (String, ScriptActor, SpanOwner)
    switch script.runner {
    case let .session(session, group): (id, actor, root) = (newScriptID(), .session(session), SpanOwner(session: session, group: group))
    case let .person(run):
      guard let token = script.token else { preconditionFailure("a terminal run reached the worker without its token") }
      (id, actor, root) = (run.id, .person(run, token: token), SpanOwner(session: nil, group: run.personalGroup))
    }
    let client = tools.client(actor)
    let execution = ScriptExecution(
      id: id,
      actor: actor,
      source: script.source,
      lifetime: .seconds(ToolLifetimes.scriptDefault),
      client: client,
      secrets: ScriptSecrets(client: client),
      tools: tools,
      kind: .command { output($0.output) },
      arguments: script.arguments,
      limits: limits,
      trace: .root(root),
    )
    let run: Task<Void, Never>
    do { run = try scope.run("script \(execution.id)") { await execution.run() } }
    catch { throw ToolProblem("this worker is stopping; the script did not start") }
    await withTaskCancellationHandler {
      await run.value
    } onCancel: {
      execution.killForCancellation()
    }
    try Task.checkCancellation()
    output(.end)
  }
}

private func newScriptID() -> String {
  @Dependency(\.uuid) var uuid
  return String(uuid().uuidString.lowercased().prefix(8))
}
