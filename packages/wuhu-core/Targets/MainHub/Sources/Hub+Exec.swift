import Dependencies
import Logging
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

/// How long the call waits before it returns `running`. Past the lifetime the
/// exec is killed anyway, so the wait stops a little after it, where that end
/// is the call's result.
func execWait(_ arguments: ExecArguments, lifetime: Double) throws -> Double {
  let wait = arguments.waitSeconds ?? ToolLifetimes.waitDefault
  guard wait > 0 else { throw ToolProblem("exec: wait_seconds must be more than 0", code: "invalidArgument") }
  return min(wait, lifetime + ToolLifetimes.lifetimeSlack)
}

func execEnvironment(_ arguments: ExecArguments) throws -> ExecEnvironment {
  try execEnvironment(env: arguments.env ?? [:], secrets: arguments.secrets ?? [:])
}

/// Where a job's end is recorded when its call still waits on it.
private struct ExecCallContext: Sendable {
  var address: Address
  var state: ToolExecutionState
}

extension Hub {
  // An exec is a job that outlives its call: the call starts it, or finds it
  // again on a retry, and waits up to wait_seconds. The end becomes the call's
  // result; past the wait the call returns `running` and the end arrives as
  // one message.
  nonisolated func exec(
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
    let wait = try execWait(arguments, lifetime: lifetime)

    let span = ServerTracing.enabled ? ServerSpan(.machine, session: session.rawValue) : nil
    var spanAttributes: [SpanAttribute: String]? = span == nil ? nil : [.machine: machine.rawValue, .version: "v1", .kind: "exec", .outcome: "error"]
    defer { if let spanAttributes { span?.finish(spanAttributes) } }
    let context = ExecCallContext(address: address, state: state)
    let job: ExecJob
    if let running = execJobs.job(session, callID) {
      // A retried call whose job still runs here waits on it again.
      job = running
    } else {
      let claim = try await backend.claim(machine, session, callID)
      let maxOutput = min(arguments.maxOutput ?? execOutputBudget, 4 << 20)
      let start = ExecStart(
        id: claim.record.id,
        cwd: cwd,
        command: ["sh", "-c", arguments.command],
        env: environment.env,
        secrets: environment.secrets,
        // Until the result is durable the consumer withholds acknowledgements,
        // so a crash-retry replays the retained stream from byte 0;
        // the window must therefore cover the full output budget.
        window: maxOutput + 65536,
        maxOutput: maxOutput,
        timeout: lifetime,
      )
      let spec = ExecJobSpec(start: start, machine: machine.rawValue, lifetime: lifetime, defaultLifetime: arguments.maxLifetimeSeconds == nil)
      @Dependency(\.uuid) var uuid
      job = ExecJob(
        session: session, call: callID, id: claim.record.id, startedAt: claim.record.startedAt,
        notice: uuid(), spec: try encodedSpec(spec),
      )
      execJobs.insert(job)
      try drive(job, spec: spec, backend: backend, context: context)
    }
    let result = try await awaitJob(job, wait: wait, context: context)
    if case let .exec(exec) = result {
      spanAttributes?[.exitCode] = String(exec.exitCode)
      spanAttributes?[.bytesOut] = String(exec.output.utf8.count)
      spanAttributes?[.outcome] = "ok"
      spanAttributes?[.verdict] = job.phase == .detached ? "running" : "exited"
    }
    return result
  }

  nonisolated public func pendingArrivals(_ session: SessionID) -> AsyncThrowingStream<[PendingArrival], any Error> {
    let snapshots = store.observePendingArrivals(session)
    return AsyncThrowingStream { continuation in
      let forward = Task {
        do {
          for try await pending in snapshots { continuation.yield(pending) }
          continuation.finish()
        } catch { continuation.finish(throwing: error) }
      }
      continuation.onTermination = { _ in forward.cancel() }
    }
  }

  nonisolated private func encodedSpec(_ spec: ExecJobSpec) throws -> String {
    String(decoding: try JSONEncoder().encode(spec), as: UTF8.self)
  }

  private enum ExecWaitEnd: Sendable {
    case ended(ExecJob.Outcome)
    case cut(WaitCut)
  }

  // Waits for the job's end up to `wait`, or less once something arrives; past it, records the call's
  // `running` receipt and the owed job in one write and returns that.
  nonisolated private func awaitJob(_ job: ExecJob, wait: Double, context: ExecCallContext) async throws -> ToolResultPayload {
    let arrivals = pendingArrivals(job.session)
    let end: ExecWaitEnd? = await withTaskGroup(of: ExecWaitEnd?.self) { group in
      group.addTask { await job.ended.wait().map(ExecWaitEnd.ended) }
      group.addTask { await WaitCut.first(wait: wait, arrivals: arrivals).map(ExecWaitEnd.cut) }
      defer { group.cancelAll() }
      return await group.next() ?? nil
    }
    try Task.checkCancellation()
    guard let end else { throw CancellationError() }
    let cut: WaitCut
    switch end {
    case let .ended(outcome): return try outcome.result()
    case let .cut(reason): cut = reason
    }
    let detached = try await job.gate.holding { () -> ExecJob.Outcome? in
      if let ended = job.ended.value { return ended }
      // Cancelled while the call waited: its end is close and is the result.
      guard job.phase == .awaited else { return nil }
      let payload = runningPayload(job, cut: cut)
      try await deliverContext(job.session, job.call, touching: context.address, state: context.state)
      try await store.detachExecJob(
        ExecJobRecord(session: job.session, toolCallID: job.call, exec: job.id, notice: job.notice, spec: job.spec, startedAt: job.startedAt),
        payload: payload,
      )
      job.phase = .detached
      return .payload(payload)
    }
    if let detached { return try detached.result() }
    guard let ended = await job.ended.wait() else { throw CancellationError() }
    return try ended.result()
  }

  nonisolated private func runningPayload(_ job: ExecJob, cut: WaitCut) -> ToolResultPayload {
    let note = "\(cut.reason); its end arrives as one message, and cancel(\"\(job.handle)\") kills it"
    return .exec(.init(output: runningJSON(job.handle, tail: job.tail, note: note), exitCode: 0))
  }

  // Runs the job's exec to its end in a task of its own, which the call that
  // started it may stop waiting on.
  nonisolated private func drive(_ job: ExecJob, spec: ExecJobSpec, backend: ExecBackend, context: ExecCallContext?) throws(ToolProblem) {
    do {
      try execJobs.drivers.run("exec job \(job.handle)") { await self.follow(job, spec: spec, backend: backend, context: context) }
    } catch {
      execJobs.remove(job)
      throw ToolProblem("the server is stopping; \(job.handle) is followed again when it starts")
    }
  }

  nonisolated private func follow(_ job: ExecJob, spec: ExecJobSpec, backend: ExecBackend, context: ExecCallContext?) async {
    let outcome: ExecJob.Outcome
    do {
      _ = try await runExec(spec.start, backend: backend, received: job.received) { drive in
        let outcome = await self.outcome(of: drive, job: job, spec: spec, backend: backend)
        try await self.settle(job, outcome, context: context)
        return outcome
      }
      return
    } catch let problem as ToolProblem {
      outcome = .problem(problem)
    } catch is CancellationError {
      // The server stops: the exec runs on, and its row brings it back.
      outcome = .problem(ToolProblem("the server stopped while \(job.handle) ran; it is followed again when it starts"))
    } catch {
      outcome = .problem(ToolProblem("\(job.handle) could not record its end: \(error)"))
      Logger(label: "wuhu.exec").warning("\(job.handle) could not record its end: \(error)")
    }
    execJobs.finish(job, outcome)
  }

  // The end goes where the job's phase says: the waiting call's receipt, one
  // message, or nowhere after a cancel. Repeating it is harmless: the receipt
  // keeps its first value and the message is deduplicated by its id.
  nonisolated private func settle(_ job: ExecJob, _ outcome: ExecJob.Outcome, context: ExecCallContext?) async throws {
    try await job.gate.holding {
      let committed: @Sendable () -> Void = { self.execJobs.finish(job, outcome) }
      switch job.phase {
      case .awaited:
        guard case let .payload(payload) = outcome else {
          committed()
          return
        }
        if let context { try await deliverContext(job.session, job.call, touching: context.address, state: context.state) }
        try await store.recordReceipt(job.session, toolCallID: job.call, payload: payload, onCommit: committed)
      case .detached:
        try await store.settleExecJob(job.session, toolCallID: job.call, notification: notice(job, outcome), onCommit: committed)
      case .cancelled:
        try await store.settleExecJob(job.session, toolCallID: job.call, notification: nil, onCommit: committed)
      }
    }
  }

  nonisolated private func notice(_ job: ExecJob, _ outcome: ExecJob.Outcome) -> SystemNotification {
    @Dependency(\.date) var date
    let text: String = switch outcome {
    case let .payload(.exec(result)):
      "\(job.handle) ended" + (result.exitCode == 0 ? "" : " with exit code \(result.exitCode)") + ":\n"
        + (result.reaped ? "[process reaped after caller absence; output buffered to termination]\n" : "") + result.output
    case .payload:
      "\(job.handle) ended"
    case let .problem(problem) where job.adopted:
      "\(job.handle) was running when the server restarted, and its outcome is unknown: \(problem.message)"
    case let .problem(problem):
      "\(job.handle) ended: \(problem.message)"
    }
    return SystemNotification(
      id: job.notice, timestamp: date.now, kind: .exec, subscriptionID: .exec(job.id.rawValue), content: .init(text: text),
    )
  }

  nonisolated private func outcome(of drive: DriveOutcome, job: ExecJob, spec: ExecJobSpec, backend: ExecBackend) async -> ExecJob.Outcome {
    let record = try? await backend.status(job.id)
    switch drive {
    case let .exited(output, status, cut, timedOut):
      if timedOut == .statusUnknown {
        return .problem(ToolProblem(
          "\(job.handle) was stopped at its \(seconds(.seconds(spec.lifetime))) s max lifetime, but its own exit status never came back",
          code: "requestDeadline",
        ))
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
      let maxOutput = spec.start.maxOutput ?? execOutputBudget
      if output.count >= maxOutput {
        text += "\n[output hit the \(maxOutput)-byte budget; the command was killed]"
      }
      if timedOut == .killed {
        text += spec.defaultLifetime
          ? "\n[killed after \(seconds(.seconds(spec.lifetime))) s, the default max lifetime; start longer work detached and watch it from run_script]"
          : "\n[killed after \(seconds(.seconds(spec.lifetime))) s, its max_lifetime_seconds]"
      }
      return .payload(.exec(.init(output: text, exitCode: exitCode, reaped: record?.terminal == .reaped)))
    case let .lost(message):
      return switch record?.terminal {
      case .cancelled: .problem(ToolProblem("\(job.handle) was cancelled"))
      case .machineLost: .problem(ToolProblem("machine \(spec.machine) stopped responding while the command ran; remote process outcome is unknown"))
      case .reaped: .problem(ToolProblem("\(job.handle) was reaped and its buffered output is no longer replayable"))
      default: .problem(ToolProblem(message))
      }
    }
  }

  fileprivate enum DriveOutcome: Sendable {
    case exited(output: [UInt8], status: ExitStatus, cut: Bool, timedOut: ExecTimeout?)
    case lost(String)
  }

  nonisolated private func runExec<Result: Sendable>(
    _ start: ExecStart, backend: ExecBackend,
    received: @escaping @Sendable ([UInt8]) -> Void,
    consume: @escaping @Sendable (DriveOutcome) async throws -> Result,
  ) async throws -> Result {
    let endpoint = ChannelEndpoint()
    let outgoing = await endpoint.startExec(start, autoAcknowledge: false)
    return try await withThrowingTaskGroup(of: Result?.self, returning: Result.self) { group in
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
              received(data.bytes)
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
        let result: Result
        do {
          result = try await consume(drive)
        } catch let problem as ToolProblem {
          throw problem
        } catch is CancellationError {
          return nil
        } catch {
          // An end that could not be recorded is recorded as why.
          return try await consume(.lost(String(describing: error)))
        }
        await outgoing.acknowledgeExit()
        return result
      }
      defer { group.cancelAll() }
      while let outcome = try await group.next() {
        if let outcome { return outcome }
      }
      throw CancellationError()
    }
  }
}

extension ExecJob.Outcome {
  nonisolated func result() throws -> ToolResultPayload {
    switch self {
    case let .payload(payload): payload
    case let .problem(problem): throw problem
    }
  }
}

extension Hub {
  // An interrupt kills the exec its call waited on. A call that already
  // returned `running` is not interrupted: its job runs on.
  nonisolated public func killInterruptedExec(session: SessionID, toolCallID: ToolCallID) async {
    if let job = execJobs.job(session, toolCallID) {
      let interrupted = try? await job.gate.holding { () -> Bool in
        guard job.phase != .detached else { return false }
        job.phase = .cancelled
        return true
      }
      guard interrupted == true else { return }
    }
    guard let record = try? await space.execRecord(caller: session.rawValue, toolCallID: toolCallID), record.terminal == nil else { return }
    try? await execBackend?.kill(record.id)
  }

  /// cancel(exec.…): SIGTERM to the process group, SIGKILL 5 s later. The
  /// end is not announced; the result says how it ended, if it does soon.
  nonisolated func cancelExec(_ session: SessionID, _ id: ExecID) async throws -> ToolResultPayload {
    let handle = execHandle(id)
    let job = execJobs.job(session, exec: id)
    if job == nil {
      guard let record = try await space.execRecord(id), record.caller == session.rawValue, record.toolCallID != nil else {
        throw ToolProblem("you have no exec \(handle)", code: "notFound")
      }
      guard record.terminal == nil else { throw ToolProblem("\(handle) has already ended", code: "alreadyEnded") }
    }
    guard let backend = execBackend else { throw ToolProblem("no machine execution backend is available on this server") }
    guard let job else {
      try await backend.kill(id)
      return .script(.init(output: "\(handle) was sent SIGTERM to its process group, and gets SIGKILL 5 s later"))
    }
    try await job.gate.holding {
      guard job.ended.value == nil else { throw ToolProblem("\(handle) has already ended", code: "alreadyEnded") }
      if job.phase == .detached { job.phase = .cancelled }
      try await backend.kill(id)
    }
    @Dependency(\.continuousClock) var continuousClock
    let clock = continuousClock
    let ended: ExecJob.Outcome? = await withTaskGroup(of: ExecJob.Outcome?.self) { group in
      group.addTask { await job.ended.wait() }
      group.addTask {
        try? await clock.sleep(for: .seconds(10))
        return nil
      }
      defer { group.cancelAll() }
      return await group.next() ?? nil
    }
    let output = switch ended {
    case let .payload(.exec(result))?: "\(handle) was killed (SIGTERM to its process group, SIGKILL 5 s later); it ended with exit code \(result.exitCode)"
    case .payload?: "\(handle) was killed"
    case let .problem(problem)?: "\(handle) was killed: \(problem.message)"
    case nil: "\(handle) was sent SIGTERM to its process group and has not ended within 10 s; SIGKILL follows 5 s after the TERM"
    }
    return .script(.init(output: output))
  }

  /// Archive's cut: every job of `session` is killed and its end goes unannounced.
  nonisolated public func cancelExecJobs(of session: SessionID) async {
    for job in execJobs.jobs(of: session) {
      try? await job.gate.holding { job.phase = .cancelled }
      try? await execBackend?.kill(job.id)
    }
  }

  /// The cancel ids of `session`'s exec jobs whose call already returned.
  nonisolated public func runningExecJobs(of session: SessionID) -> [String] { execJobs.running(of: session) }

  /// At boot: follows every job a restart interrupted to its end, which
  /// arrives as the message it owed. A job that cannot be followed says so.
  nonisolated public func adoptExecJobs() async {
    let rows: [ExecJobRecord]
    do { rows = try await store.execJobs() } catch {
      Logger(label: "wuhu.exec").error("could not read the exec jobs a restart interrupted: \(error)")
      return
    }
    for row in rows where execJobs.job(row.session, row.toolCallID) == nil {
      let job = ExecJob(
        session: row.session, call: row.toolCallID, id: row.exec, startedAt: row.startedAt,
        notice: row.notice, spec: row.spec, phase: .detached, adopted: true,
      )
      guard let backend = execBackend, let spec = try? JSONDecoder().decode(ExecJobSpec.self, from: Data(row.spec.utf8)) else {
        do { try await settle(job, .problem(ToolProblem("this server cannot rejoin it")), context: nil) }
        catch { Logger(label: "wuhu.exec").error("\(job.handle) could not deliver its end: \(error)") }
        continue
      }
      execJobs.insert(job)
      do { try drive(job, spec: spec, backend: backend, context: nil) } catch {
        Logger(label: "wuhu.exec").warning("\(job.handle) was not re-adopted: \(error.message)")
      }
    }
  }

  /// Stops following the jobs, as a server stop does: their execs run on,
  /// and their rows stay for the next start to re-adopt.
  nonisolated public func closeExecJobs() async {
    await execJobs.drivers.close()
  }
}
