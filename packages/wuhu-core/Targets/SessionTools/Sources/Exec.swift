import struct MachineContract.MachineID
import enum MainHub.Address
import enum MainHub.Addressing
import struct MainHub.ExecArguments
import func MainHub.execEnvironment
import func MainHub.execLifetime
import func MainHub.execWait
import func MainHub.runningJSON
import func MainHub.seconds
import struct MainHub.ToolProblem
import enum MainHub.WaitCut
import SessionDomain
import SpaceCore
import struct WuhuAI.ToolCall
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

public struct ExecToolPlan: Sendable {
  public let machine: String
  public let cwd: String
  public let argv: [String]
  public let env: [String: String]
  public let secrets: [String: String]
  public let maxOutput: Int
  public let lifetime: Double
  public let wait: Double
  public let defaultLifetime: Bool

  public init(_ call: ToolCall) throws {
    let arguments: ExecArguments
    do { arguments = try call.arguments.decode(ExecArguments.self) }
    catch { throw ToolProblem("exec: arguments do not match the tool schema: \(error)") }
    guard arguments.cwd.hasPrefix("/"), !arguments.machine.contains("/") else {
      throw ToolProblem("exec takes a machine name or id and an absolute cwd on it, got machine \(arguments.machine), cwd \(arguments.cwd)")
    }
    machine = arguments.machine
    cwd = try Addressing.normalize(arguments.cwd)
    argv = ["sh", "-c", arguments.command]
    let environment = try execEnvironment(arguments)
    env = environment.env?.entries ?? [:]
    secrets = environment.secrets?.entries ?? [:]
    maxOutput = min(arguments.maxOutput ?? (1 << 20), 4 << 20)
    guard maxOutput > 0 else { throw ToolProblem("exec: max_output must be more than 0", code: "invalidArgument") }
    lifetime = try execLifetime(arguments)
    wait = try execWait(arguments, lifetime: lifetime)
    defaultLifetime = arguments.maxLifetimeSeconds == nil
  }

  public func running(_ id: String, tail: Data, cut: WaitCut) -> ToolResultPayload {
    let handle = "exec.\(id)"
    return .exec(.init(output: runningJSON(handle, tail: ToolOutput.tail(String(decoding: tail.suffix(16384), as: UTF8.self), maxLines: 40, maxBytes: 4096).text, note: "\(cut.reason); cancel(\"\(handle)\") kills it"), exitCode: 0))
  }

  public func finished(_ end: ExecFinished) -> ToolResultPayload {
    if let error = end.error {
      return .failure(.init(message: error.message, code: error.code.rawValue))
    }
    let exitCode: Int32
    switch end.status! {
    case let .exited(code): exitCode = Int32(truncatingIfNeeded: code)
    case let .signaled(signal): exitCode = Int32(128 + signal)
    }
    let clamp = ToolOutput.tail(String(decoding: end.tail, as: UTF8.self))
    var text = clamp.text
    if clamp.clamped || end.cursor > end.tail.count { text += "\n[showing the tail of \(end.cursor) bytes of output]" }
    if end.cut { text += "\n[output was cut when the command stopped]" }
    if end.cursor >= maxOutput { text += "\n[output hit the \(maxOutput)-byte budget; the command was killed]" }
    if end.timedOut == .killed {
      text += defaultLifetime
        ? "\n[killed after \(seconds(.seconds(lifetime))) s, the default max lifetime; start longer work detached and watch it from run_script]"
        : "\n[killed after \(seconds(.seconds(lifetime))) s, its max_lifetime_seconds]"
    }
    return .exec(.init(output: text, exitCode: exitCode))
  }
}

extension ToolExecutor {
  public func execContext(_ session: SessionID, machine: MachineID, cwd: String, state: ToolExecutionState) async -> ScopeContext? {
    await deliverContext(session, touching: .machine(machine, cwd), state: state)
  }
}
