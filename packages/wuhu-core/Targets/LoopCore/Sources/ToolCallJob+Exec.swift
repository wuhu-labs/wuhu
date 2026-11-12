import struct MachineContract.MachineID
import struct MainHub.ToolProblem
import enum MainHub.WaitCut
import SessionDomain
import SessionTools
import SpaceCore
import StructuredQueries
import Wuwei
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

struct ToolExecTarget: Codable {
  var machine: String
  var id: String
  var waitUntil: Date
  var yieldBy: Date?
}

extension ToolCallJob {
  mutating func exec(state: ToolExecutionState, saved: ToolExecTarget?) async throws -> Outcome {
    let client = ctx.dependency(LoopClient.self)
    let params = ctx.params
    do {
      let plan = try ExecToolPlan(params.call)
      var exec: ToolExecTarget
      let context: ScopeContext?
      if let saved {
        exec = saved
        context = try await ctx.effect {
          await client.tools.execContext(params.session, machine: MachineID(rawValue: saved.machine), cwd: plan.cwd, state: state)
        }
      } else {
        let (machine, request, preparedContext) = try await ctx.effect {
          let session = try await client.space.sessions.record(params.session)
          guard let machine = try await client.space.resolveMachine(plan.machine, usableFrom: session.group) else {
            throw ToolProblem("unknown machine: \(plan.machine)")
          }
          let operation = UUID.deterministic("machine-exec", params.session.rawValue, params.call.id)
          let bits = operation.uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
          let suffix = String(UInt64(bits, radix: 16)!, radix: 36)
          let id = "ex_" + String(repeating: "0", count: 8 - suffix.count) + suffix
          let request = MachineExec(
            id: id,
            operation: operation,
            createdAt: client.now(),
            group: session.group,
            caller: params.session.rawValue,
            session: params.session,
            toolCall: ToolCallID(params.call.id),
            attribution: .init(session: params.session.rawValue, title: session.title, group: session.group.rawValue),
            argv: plan.argv,
            cwd: plan.cwd,
            env: plan.env,
            secrets: plan.secrets,
            window: plan.maxOutput + 65536,
            maxOutput: plan.maxOutput,
            timeout: plan.lifetime,
          )
          let context = await client.tools.execContext(params.session, machine: machine.id, cwd: plan.cwd, state: state)
          return (machine.id, request, context)
        }
        exec = ToolExecTarget(machine: machine.rawValue, id: request.id, waitUntil: client.now().addingTimeInterval(plan.wait), yieldBy: params.yieldBy)
        context = preparedContext
        ctx.send(MachineCell.ID(exec.machine)).start(request, finished: id.recipient.retyped())
        try db.execute(CallRow.update { $0.started = true; $0.exec = #bind(exec) })
      }
      while true {
        let until = min(exec.waitUntil, exec.yieldBy ?? exec.waitUntil)
        let left = max(0, until.timeIntervalSince(client.now()))
        guard let message = try await ctx.receive(within: .seconds(left)) else {
          let tail = ctx.cell(MachineCell.ID(exec.machine)).tail(exec.id)
          ctx.send(MachineCell.ID(exec.machine)).detach(exec.id)
          return try answer(.result(plan.running(exec.id, tail: tail, cut: until < exec.waitUntil ? .arrival : .waited(plan.wait)), context: context))
        }
        switch message {
        case let .finished(end):
          precondition(end.id == exec.id)
          ctx.send(MachineCell.ID(exec.machine)).taken(exec.id)
          return try answer(.result(plan.finished(end), context: context))
        case .interrupt:
          ctx.send(MachineCell.ID(exec.machine)).abandon(exec.id)
          return try answer(.interrupted)
        case let .yield(by):
          exec.yieldBy = min(exec.yieldBy ?? by, by)
          try db.execute(CallRow.update { $0.exec = #bind(exec) })
        }
      }
    } catch let error as ToolProblem {
      return try answer(.result(.failure(.init(message: error.message, code: error.code)), context: nil))
    }
  }
}
