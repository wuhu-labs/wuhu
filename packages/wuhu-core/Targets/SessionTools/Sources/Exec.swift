import Dependencies
import Foundation
import MachineChannel
import enum MachineContract.ExecEvent
import struct MachineContract.ExecID
import struct MachineContract.ExecStart
import enum MachineContract.ExitStatus
import struct MachineContract.StringMap
import SessionDomain
import SpaceCore

let execOutputBudget = 1 << 20

struct ExecEnvironment: Equatable, Sendable {
  var env: StringMap?
  var secrets: StringMap?
}

func execEnvironment(_ arguments: ExecArguments) throws -> ExecEnvironment {
  try execEnvironment(env: arguments.env ?? [:], secrets: arguments.secrets ?? [:])
}

func execEnvironment(env: [String: String], secrets: [String: String]) throws -> ExecEnvironment {
  for name in env.keys.sorted() where !isEnvironmentName(name) {
    throw ToolProblem("exec: '\(name)' is not a usable environment variable name")
  }
  for name in secrets.keys.sorted() where !isEnvironmentName(name) {
    throw ToolProblem("exec: '\(name)' is not a usable environment variable name")
  }
  let both = Set(env.keys).intersection(secrets.keys).sorted()
  if let clash = both.first {
    throw ToolProblem("exec: '\(clash)' is set by both env and secrets; pick one")
  }
  return ExecEnvironment(
    env: env.isEmpty ? nil : StringMap(env),
    secrets: secrets.isEmpty ? nil : StringMap(secrets),
  )
}

private func isEnvironmentName(_ name: String) -> Bool {
  var utf8 = name.utf8.makeIterator()
  guard let first = utf8.next(), first == UInt8(ascii: "_") || isASCIILetter(first) else { return false }
  while let byte = utf8.next() {
    guard byte == UInt8(ascii: "_") || isASCIILetter(byte) || (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
    else { return false }
  }
  return true
}

private func isASCIILetter(_ byte: UInt8) -> Bool {
  (UInt8(ascii: "a") ... UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte)
}

extension ToolExecutor {
  func exec(
    _ session: SessionID,
    _ callID: ToolCallID,
    _ arguments: ExecArguments,
    state: ToolExecutionState,
  ) async throws -> ToolResultPayload {
    guard arguments.cwd.hasPrefix("/"), !arguments.machine.contains("/") else {
      throw ToolProblem("exec takes a machine name or id and an absolute cwd on it, got machine \(arguments.machine), cwd \(arguments.cwd)")
    }
    let address = try await resolve("machines://\(arguments.machine)\(arguments.cwd)", as: session)
    guard case let .machine(machine, cwd) = address else {
      preconditionFailure("a machines:// address resolved into the space")
    }
    guard let backend = execBackend else {
      throw ToolProblem("no machine execution backend is available on this server")
    }
    let environment = try execEnvironment(arguments)
    if let recorded = try await store.receipt(session, toolCallID: callID) { return recorded }

    let claim = try await backend.claim(machine, session, callID)
    let maxOutput = min(arguments.maxOutput ?? execOutputBudget, 4 << 20)
    let start = ExecStart(
      id: claim.record.id,
      cwd: cwd,
      command: ["sh", "-c", arguments.command],
      env: environment.env,
      secrets: environment.secrets,
      // The consumer never acks (autoAcknowledge: false), so the machine
      // retains the whole stream and a crash-retry replays it from byte 0;
      // the window must therefore cover the full output budget.
      window: maxOutput + 65536,
      maxOutput: maxOutput,
      timeout: arguments.timeoutSeconds,
    )
    // Cancellation deliberately does NOT kill the process: the executor
    // cannot tell an interrupt from a crash-shaped teardown, and a crash
    // retry must be able to rejoin the still-running exec. An interrupted
    // exec is never retried, so its caller leg stays gone and the
    // machine-domain rejoin deadline delivers the kill.
    let drive = try await runExec(start, backend: backend)

    var record: ExecRecord?
    if let fetched = try? await backend.status(claim.record.id) { record = fetched }
    switch drive {
    case let .exited(output, status):
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
      if output.count >= maxOutput {
        text += "\n[output hit the \(maxOutput)-byte budget; the command was killed]"
      }
      let payload = ToolResultPayload.exec(.init(output: text, exitCode: exitCode, reaped: record?.terminal == .reaped))
      try await deliverContext(session, callID, touching: address, state: state)
      try await store.recordReceipt(session, toolCallID: callID, payload: payload)
      return payload
    case let .lost(message):
      switch record?.terminal {
      case .cancelled:
        throw ToolProblem("exec \(claim.record.id.rawValue) was cancelled")
      case .machineLost:
        throw ToolProblem("machine \(machine.rawValue) was lost while the command ran; output is not replayable")
      case .reaped:
        throw ToolProblem("exec \(claim.record.id.rawValue) was reaped and its buffered output is no longer replayable")
      default:
        throw ToolProblem(message)
      }
    }
  }

  private enum DriveOutcome: Sendable {
    case exited(output: [UInt8], status: ExitStatus)
    case lost(String)
  }

  private func runExec(_ start: ExecStart, backend: ExecBackend) async throws -> DriveOutcome {
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(start, autoAcknowledge: false)
    return try await withThrowingTaskGroup(of: DriveOutcome?.self, returning: DriveOutcome.self) { group in
      group.addTask {
        try await holdExecLeg(start.id, endpoint: endpoint, backend: backend).map(DriveOutcome.lost)
      }
      group.addTask {
        await outgoing.closeStdin()
        var output: [UInt8] = []
        do {
          for try await event in outgoing.events {
            switch event {
            case let .output(_, _, data):
              output += data.bytes
            case let .exit(status):
              return .exited(output: output, status: status)
            case .truncated:
              continue
            case let .failed(error):
              return .lost(error.message)
            }
          }
        } catch is CancellationError {
          return nil
        } catch {
          return .lost(String(describing: error))
        }
        if Task.isCancelled { return nil }
        return .lost("exec stream ended without an exit event")
      }
      defer { group.cancelAll() }
      while let outcome = try await group.next() {
        if let outcome { return outcome }
      }
      throw CancellationError()
    }
  }
}

// Keeps an exec's caller leg dialed, re-dialing with backoff, and returns why it
// gave up (nil once cancelled). With `abandoningLost`, a machine-lost verdict
// ends it at once instead of waiting for the machine to come back.
func holdExecLeg(
  _ id: ExecID,
  endpoint: ChannelEndpoint,
  backend: ExecBackend,
  abandoningLost: Bool = false,
) async throws -> String? {
  let clock: any Clock<Duration> = Dependency(\.continuousClock).wrappedValue
  var unreachable = 0
  while !Task.isCancelled {
    do {
      let transport = try await backend.connect(id)
      unreachable = 0
      await endpoint.run(transport)
    } catch is CancellationError {
      return nil
    } catch {
      unreachable += 1
    }
    if Task.isCancelled { return nil }
    if let record = try? await backend.status(id), let terminal = record.terminal {
      if abandoningLost, terminal == .machineLost {
        return "machine \(record.machine.rawValue) was lost"
      }
      // Terminal without a delivered exit: one more round may still
      // drain the buffered tail; a second sever means it cannot.
      unreachable += 4
    }
    if unreachable >= 8 {
      return "machine connection for exec \(id.rawValue) failed; the run may still be tracked server-side"
    }
    try await clock.sleep(for: .milliseconds(50 * (1 << min(unreachable, 5))))
  }
  return nil
}
