import Dependencies
import ServerTelemetry
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineChannel
import enum MachineContract.ExecEvent
import struct MachineContract.ExecID
import struct MachineContract.ExecStart
import enum MachineContract.ExecTimeout
import enum MachineContract.ExitStatus
import struct MachineContract.StringMap
import SessionDomain
import SpaceCore

let execOutputBudget = 1 << 20

struct ExecEnvironment: Equatable, Sendable {
  var env: StringMap?
  var secrets: StringMap?
}

func execLifetime(_ arguments: ExecArguments) throws -> Double {
  if arguments.timeoutSeconds != nil {
    throw ToolProblem("exec: timeout_seconds is renamed to max_lifetime_seconds", code: "invalidArgument")
  }
  let lifetime = arguments.maxLifetimeSeconds ?? ToolLifetimes.execDefault
  guard lifetime > 0, lifetime <= ToolLifetimes.ceiling else {
    throw ToolProblem("exec: max_lifetime_seconds must be more than 0 and at most \(seconds(.seconds(ToolLifetimes.ceiling)))", code: "invalidArgument")
  }
  return lifetime
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

extension InProcessToolOwnerClient {
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
    let lifetime = try execLifetime(arguments)

    let span = ServerTracing.enabled ? ServerSpan(.machine, session: session.rawValue) : nil
    var spanAttributes: [SpanAttribute: String]? = span == nil ? nil : [.machine: machine.rawValue, .version: "v1", .kind: "exec", .outcome: "error"]
    defer { if let spanAttributes { span?.finish(spanAttributes) } }
    let claim = try await backend.claim(machine, session, callID)
    let maxOutput = min(arguments.maxOutput ?? execOutputBudget, 4 << 20)
    let start = ExecStart(
      id: claim.record.id,
      cwd: cwd,
      command: ["sh", "-c", arguments.command],
      env: environment.env,
      secrets: environment.secrets,
      // Until the receipt is durable the consumer withholds acknowledgements,
      // so a crash-retry replays the retained stream from byte 0;
      // the window must therefore cover the full output budget.
      window: maxOutput + 65536,
      maxOutput: maxOutput,
      timeout: lifetime,
    )
    // Cancellation deliberately does NOT kill the process: the executor
    // cannot tell an interrupt from a crash-shaped teardown, and a crash
    // retry must be able to rejoin the still-running exec. An interrupted
    // exec is never retried, so its caller leg stays gone and the
    // machine-domain rejoin deadline delivers the kill.
    let result = try await runExec(start, backend: backend) { drive in
      var record: ExecRecord?
      if let fetched = try? await backend.status(claim.record.id) { record = fetched }
      switch drive {
      case let .exited(output, status, cut, timedOut):
        if timedOut == .statusUnknown {
          throw ToolProblem(
            "exec \(claim.record.id.rawValue) was stopped at its \(seconds(.seconds(lifetime))) s max lifetime, but its own exit status never came back",
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
        if output.count >= maxOutput {
          text += "\n[output hit the \(maxOutput)-byte budget; the command was killed]"
        }
        if timedOut == .killed {
          text += arguments.maxLifetimeSeconds == nil
            ? "\n[killed after \(seconds(.seconds(lifetime))) s, the default max lifetime; start longer work detached and watch it from run_script]"
            : "\n[killed after \(seconds(.seconds(lifetime))) s, its max_lifetime_seconds]"
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
          throw ToolProblem("machine \(machine.rawValue) stopped responding while the command ran; remote process outcome is unknown")
        case .reaped:
          throw ToolProblem("exec \(claim.record.id.rawValue) was reaped and its buffered output is no longer replayable")
        default:
          throw ToolProblem(message)
        }
      }
    }
    if case let .exec(exec) = result {
      spanAttributes?[.exitCode] = String(exec.exitCode)
      spanAttributes?[.bytesOut] = String(exec.output.utf8.count)
      spanAttributes?[.outcome] = "ok"
      spanAttributes?[.verdict] = "exited"
    }
    return result
  }

  private enum DriveOutcome: Sendable {
    case exited(output: [UInt8], status: ExitStatus, cut: Bool, timedOut: ExecTimeout?)
    case lost(String)
  }

  private func runExec(
    _ start: ExecStart, backend: ExecBackend,
    consume: @escaping @Sendable (DriveOutcome) async throws -> ToolResultPayload,
  ) async throws -> ToolResultPayload {
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(start, autoAcknowledge: false)
    return try await withThrowingTaskGroup(of: ToolResultPayload?.self, returning: ToolResultPayload.self) { group in
      group.addTask {
        if let message = try await holdExecLeg(start.id, endpoint: endpoint, backend: backend) {
          return try await consume(.lost(message))
        }
        return nil
      }
      group.addTask {
        await outgoing.closeStdin()
        var output: [UInt8] = []
        var cut = false
        var timedOut: ExecTimeout?
        var drive: DriveOutcome?
        // The result is built outside the stream's catch, so a refusal it
        // throws reaches the caller as itself, not as a lost stream.
        do {
          events: for try await event in outgoing.events {
            switch event {
            case let .output(_, _, data):
              output += data.bytes
            case let .exit(status):
              drive = .exited(output: output, status: status, cut: cut, timedOut: timedOut)
              break events
            case .truncated:
              cut = true
            case let .timedOut(outcome):
              timedOut = outcome
            case let .failed(error):
              drive = .lost(error.message)
              break events
            }
          }
        } catch is CancellationError {
          return nil
        } catch {
          drive = .lost(String(describing: error))
        }
        guard let drive else {
          if Task.isCancelled { return nil }
          return try await consume(.lost("exec stream ended without an exit event"))
        }
        guard case .exited = drive else { return try await consume(drive) }
        let payload: ToolResultPayload
        do {
          payload = try await consume(drive)
        } catch let problem as ToolProblem {
          throw problem
        } catch is CancellationError {
          return nil
        } catch {
          // A result that could not be recorded fails the call with why.
          return try await consume(.lost(String(describing: error)))
        }
        await outgoing.acknowledgeExit()
        return payload
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
// gave up (nil once cancelled). A machine-lost verdict never proves process exit.
func holdExecLeg(
  _ id: ExecID,
  endpoint: ChannelEndpoint,
  backend: ExecBackend,
) async throws -> String? {
  let clock: any Clock<Duration> = Dependency(\.continuousClock).wrappedValue
  var unreachable = 0
  var terminalSevers = 0
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
      if terminal == .machineLost {
        return "machine \(record.machine.rawValue) stopped responding; remote process outcome is unknown"
      }
      // Terminal without a delivered exit: one more round may still
      // drain the buffered tail; a second sever means it cannot.
      terminalSevers += 1
      if terminalSevers >= 2 {
        return "exec \(id.rawValue) is finished and its stream is no longer replayable"
      }
    }
    if unreachable >= 8 {
      return "machine connection for exec \(id.rawValue) failed; the run may still be tracked server-side"
    }
    try await clock.sleep(for: .milliseconds(50 * (1 << min(unreachable, 5))))
  }
  return nil
}

extension InProcessToolOwnerClient {
  public func killInterruptedExec(session: SessionID, toolCallID: ToolCallID) async {
    guard let record = try? await space.execRecord(caller: session.rawValue, toolCallID: toolCallID), record.terminal == nil else { return }
    try? await execBackend?.kill(record.id)
  }
}
