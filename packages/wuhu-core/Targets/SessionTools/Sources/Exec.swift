import Dependencies
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import enum MachineContract.ExecEvent
import struct MachineContract.ExecID
import struct MachineContract.ExecMintOutput
import struct MachineContract.ExecStart
import struct MachineContract.ExecStatus
import enum MachineContract.ExecTimeout
import enum MachineContract.ExitStatus
import struct MachineContract.StringMap
import enum MainHub.Addressing
import struct MainHub.ExecArguments
import func MainHub.execEnvironment
import func MainHub.execHandle
import func MainHub.execLifetime
import func MainHub.execWait
import func MainHub.runningJSON
import func MainHub.seconds
import struct MainHub.ToolProblem
import enum MainHub.WaitCut
import SessionDomain
import SpaceClient

private let execOutputBudget = 1 << 20

extension ToolExecutor {
  /// Runs the command and follows it to its end, unless `wait_seconds` passes or the call is told to yield first: then it answers `running` and stops following.
  func exec(_ session: SessionID, _ callID: ToolCallID, _ arguments: ExecArguments, yielded: @escaping @Sendable () async -> Bool) async throws -> ToolResultPayload {
    guard arguments.cwd.hasPrefix("/"), !arguments.machine.contains("/") else {
      throw ToolProblem("exec takes a machine name or id and an absolute cwd on it, got machine \(arguments.machine), cwd \(arguments.cwd)")
    }
    guard let machine = try await machine(arguments.machine, as: .session(session)) else {
      throw ToolProblem("unknown machine: \(arguments.machine)")
    }
    let cwd = try Addressing.normalize(arguments.cwd)
    let environment = try execEnvironment(arguments)
    let lifetime = try execLifetime(arguments)
    let wait = try execWait(arguments, lifetime: lifetime)
    let client = try await client(session, toolCall: callID.rawValue)
    let spec = ExecJobSpec(
      cwd: cwd,
      command: ["sh", "-c", arguments.command],
      env: environment.env,
      secrets: environment.secrets,
      maxOutput: min(arguments.maxOutput ?? execOutputBudget, 4 << 20),
      machine: machine.id.rawValue,
      lifetime: lifetime,
      defaultLifetime: arguments.maxLifetimeSeconds == nil,
    )
    let encoded = try JSONEncoder().encode(spec)
    let value = try JSONDecoder().decode(JSONValue.self, from: encoded)
    let minted: ExecMintOutput = try await client.api(.post, "/v1/exec", body: .object(["machine": .string(machine.id.rawValue), "spec": value]))
    let handle = execHandle(minted.id)
    let connection = ExecSession(client: client, start: spec.start(id: minted.id))
    let buffer = ExecBuffer()
    let end: ExecWaitEnd? = await withTaskGroup(of: ExecWaitEnd?.self) { group in
      group.addTask {
        do {
          return .ended(try await connection.run(failOnRemoteError: true, input: .closed, output: { _, bytes in
            await buffer.received(bytes)
          }, onEvent: { event in await buffer.event(event) }))
        } catch {
          return .ended(.streamFailed(String(describing: error)))
        }
      }
      // `running` is true only of an exec the server holds: until it does, the call keeps the leg that carries the start.
      group.addTask {
        await connection.accepted()
        return await WaitCut.first(wait: wait, yielded: yielded).map(ExecWaitEnd.cut)
      }
      defer { group.cancelAll() }
      while let next = await group.next() {
        if let next { return next }
        if Task.isCancelled { return nil }
      }
      return nil
    }
    try Task.checkCancellation()
    switch end {
    case let .ended(termination)?:
      return try await outcome(of: buffer.outcome(termination), handle: handle, id: minted.id, spec: spec, client: client)
    case let .cut(cut)?:
      let _: BackgroundReply = try await client.api(.post, "/v1/exec/\(minted.id.rawValue)/background")
      let note = "\(cut.reason); cancel(\"\(handle)\") kills it"
      return .exec(.init(output: runningJSON(handle, tail: await buffer.tail, note: note), exitCode: 0))
    case nil:
      throw CancellationError()
    }
  }

  private struct BackgroundReply: Decodable {}

  private enum ExecWaitEnd: Sendable {
    case ended(ExecSession.Termination)
    case cut(WaitCut)
  }

  private func outcome(of drive: DriveOutcome, handle: String, id: ExecID, spec: ExecJobSpec, client: SpaceClient) async throws -> ToolResultPayload {
    let record: ExecStatus? = try? await client.api(.get, "/v1/exec/\(id.rawValue)")
    switch drive {
    case let .exited(output, status, cut, timedOut):
      if timedOut == .statusUnknown {
        throw ToolProblem(
          "\(handle) was stopped at its \(seconds(.seconds(spec.lifetime))) s max lifetime, but its own exit status never came back",
          code: "requestDeadline",
        )
      }
      let exitCode: Int32 = switch status {
      case let .exited(code): Int32(truncatingIfNeeded: code)
      case let .signaled(signal): Int32(128 + signal)
      }
      // The transcript gets the tail: the end of a run is where the verdict is.
      let full = String(decoding: output, as: UTF8.self)
      let clamp = ToolOutput.tail(full)
      var text = clamp.text
      if clamp.clamped {
        let extent = clamp.shownLines.map { "lines \($0.lowerBound)-\($0.upperBound) of \(clamp.totalLines)" }
          ?? "the tail of the last line"
        text += "\n[output was \(output.count) bytes; showing \(extent)]"
      }
      if cut { text += "\n[output was cut when the command stopped]" }
      let maxOutput = spec.maxOutput
      if output.count >= maxOutput {
        text += "\n[output hit the \(maxOutput)-byte budget; the command was killed]"
      }
      if timedOut == .killed {
        text += spec.defaultLifetime
          ? "\n[killed after \(seconds(.seconds(spec.lifetime))) s, the default max lifetime; start longer work detached and watch it from run_script]"
          : "\n[killed after \(seconds(.seconds(spec.lifetime))) s, its max_lifetime_seconds]"
      }
      return .exec(.init(output: text, exitCode: exitCode, reaped: record?.state == .reaped))
    case let .lost(message):
      throw switch record?.state {
      case .cancelled: ToolProblem("\(handle) was cancelled")
      case .machineLost: ToolProblem("machine \(spec.machine) stopped responding while the command ran; remote process outcome is unknown")
      case .reaped: ToolProblem("\(handle) was reaped and its buffered output is no longer replayable")
      default: ToolProblem(message)
      }
    }
  }

  fileprivate enum DriveOutcome: Sendable {
    case exited(output: [UInt8], status: ExitStatus, cut: Bool, timedOut: ExecTimeout?)
    case lost(String)
  }
}

private actor ExecBuffer {
  var bytes: [UInt8] = []
  var cut = false
  var timedOut: ExecTimeout?

  func received(_ chunk: [UInt8]) { bytes += chunk }

  /// The end of the output so far, for the `running` answer.
  var tail: String {
    ToolOutput.tail(String(decoding: bytes.suffix(16384), as: UTF8.self), maxLines: 40, maxBytes: 4096).text
  }

  func event(_ event: ExecEvent) {
    switch event {
    case .truncated: cut = true
    case let .timedOut(value): timedOut = value
    case .output, .exit, .failed: break
    }
  }

  func outcome(_ termination: ExecSession.Termination) -> ToolExecutor.DriveOutcome {
    switch termination {
    case let .exited(code): .exited(output: bytes, status: .exited(code: Int(code)), cut: cut, timedOut: timedOut)
    case let .signaled(signal, _): .exited(output: bytes, status: .signaled(signal: signal), cut: cut, timedOut: timedOut)
    case .cancelled: .lost("exec was cancelled")
    case let .machineLost(machine): .lost("machine \(machine.rawValue) stopped responding while the command ran; remote process outcome is unknown")
    case .tailLost: .lost("exec stream ended without an exit event")
    case let .streamFailed(message): .lost(message)
    case .unreachable: .lost("exec stream ended without an exit event")
    case .interrupted: .lost("exec stream ended without an exit event")
    }
  }
}

struct ExecJobSpec: Codable, Sendable {
  struct Start: Codable, Sendable {
    var cwd: String
    var command: [String]
    var env: StringMap?
    var secrets: StringMap?
    var maxOutput: Int
  }

  var start: Start
  var machine: String
  var lifetime: Double
  var defaultLifetime: Bool
  var maxOutput: Int { start.maxOutput }

  init(cwd: String, command: [String], env: StringMap?, secrets: StringMap?, maxOutput: Int, machine: String, lifetime: Double, defaultLifetime: Bool) {
    start = Start(cwd: cwd, command: command, env: env, secrets: secrets, maxOutput: maxOutput)
    self.machine = machine
    self.lifetime = lifetime
    self.defaultLifetime = defaultLifetime
  }

  func start(id: ExecID) -> ExecStart {
    ExecStart(
      id: id,
      cwd: start.cwd,
      command: start.command,
      env: start.env,
      secrets: start.secrets,
      window: start.maxOutput + 65536,
      maxOutput: start.maxOutput,
      timeout: lifetime,
    )
  }
}
