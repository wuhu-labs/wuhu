import Dependencies
import Logging
import ServerTelemetry
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import JSONValue
import enum MachineContract.ExecEvent
import struct MachineContract.ExecID
import struct MachineContract.ExecMintInput
import struct MachineContract.ExecMintOutput
import struct MachineContract.ExecStatus
import enum MachineContract.ExecTimeout
import enum MachineContract.ExitStatus
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
import SpaceCore

private let execOutputBudget = 1 << 20

extension ToolExecutor {
  @TaskLocal static var execLog = Logger(label: "wuhu.exec")

  func exec(_ session: SessionID, _ callID: ToolCallID, _ arguments: ExecArguments) async throws -> ToolResultPayload {
    guard arguments.cwd.hasPrefix("/"), !arguments.machine.contains("/") else {
      throw ToolProblem("exec takes a machine name or id and an absolute cwd on it, got machine \(arguments.machine), cwd \(arguments.cwd)")
    }
    guard let machine = try await machine(arguments.machine, as: session) else {
      throw ToolProblem("unknown machine: \(arguments.machine)")
    }
    let cwd = try Addressing.normalize(arguments.cwd)
    let environment = try execEnvironment(arguments)
    let lifetime = try execLifetime(arguments)
    let wait = try execWait(arguments, lifetime: lifetime)
    let client = try await client(session, toolCall: callID.rawValue)
    let span = ServerTracing.enabled ? ServerSpan(.machine, session: session.rawValue) : nil
    var attributes: [SpanAttribute: String]? = span == nil ? nil : [.machine: machine.id.rawValue, .version: "v1", .kind: "exec", .outcome: "error"]
    defer { if let attributes { span?.finish(attributes) } }
    let job: ExecJob
    if let running = execJobs.job(session, callID) {
      try await running.gate.holding {
        if running.phase == .detaching { running.phase = .awaited }
      }
      job = running
    } else {
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
      let status: ExecStatus = try await client.api(.get, "/v1/exec/\(minted.id.rawValue)")
      job = ExecJob(
        session: session,
        call: callID,
        id: minted.id,
        startedAt: Date(timeIntervalSince1970: status.startedAt),
        notice: UUID.deterministic("exec-end", session.rawValue, callID.rawValue),
        spec: String(decoding: encoded, as: UTF8.self),
      )
      execJobs.insert(job)
      try drive(job, spec: spec, client: client)
    }
    let result = try await awaitJob(job, wait: wait)
    if case let .exec(exec) = result {
      attributes?[.exitCode] = String(exec.exitCode)
      attributes?[.bytesOut] = String(exec.output.utf8.count)
      attributes?[.outcome] = "ok"
      attributes?[.verdict] = job.phase == .detaching || job.phase == .detached ? "running" : "exited"
    }
    return result
  }

  private enum ExecWaitEnd: Sendable {
    case ended(ExecJob.Outcome)
    case cut(WaitCut)
  }

  private func awaitJob(_ job: ExecJob, wait: Double) async throws -> ToolResultPayload {
    let arrivals = owner.pendingArrivals(job.session)
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
      guard job.phase == .awaited else { return nil }
      let client = try await client(job.session)
      let _: ExecJobReply = try await client.api(.post, "/v1/exec/\(job.id.rawValue)/detach")
      job.phase = .detaching
      return .payload(runningPayload(job, cut: cut))
    }
    if let detached { return try detached.result() }
    guard let ended = await job.ended.wait() else { throw CancellationError() }
    return try ended.result()
  }

  private func runningPayload(_ job: ExecJob, cut: WaitCut) -> ToolResultPayload {
    let note = "\(cut.reason); its end arrives as one message, and cancel(\"\(job.handle)\") kills it"
    return .exec(.init(output: runningJSON(job.handle, tail: job.tail, note: note), exitCode: 0))
  }

  func drive(_ job: ExecJob, spec: ExecJobSpec, client: SpaceClient) throws(ToolProblem) {
    do {
      let task = try execJobs.drivers.run("exec job \(job.handle)") { await self.follow(job, spec: spec, client: client) }
      job.driver.withLock { $0 = task }
    } catch {
      execJobs.remove(job)
      throw ToolProblem("the server is stopping; \(job.handle) is followed again when it starts")
    }
  }

  private func follow(_ job: ExecJob, spec: ExecJobSpec, client: SpaceClient) async {
    let connection = ExecSession(client: client, start: spec.start(id: job.id))
    let buffer = ExecBuffer()
    do {
      _ = try await connection.run(autoAcknowledge: false, failOnRemoteError: true, input: .closed, output: { _, bytes in
        await buffer.received(bytes)
        job.received(bytes)
      }, onEvent: { event in await buffer.event(event) }, onTermination: { termination in
        guard !Task.isCancelled else {
          self.execJobs.finish(job, .problem(ToolProblem("the server stopped while \(job.handle) ran; it is followed again when it starts")))
          return
        }
        let drive = await buffer.outcome(termination)
        let outcome = await self.outcome(of: drive, job: job, spec: spec, client: client)
        do {
          try await self.settle(job, outcome)
          // The waiting tool result owns the acknowledgement; a dropped result
          // leaves the relay's replay intact for the retry.
          guard await job.committed.wait() == true else { return }
          await connection.acknowledgeExit()
        } catch {
          self.execJobs.finish(job, .problem(ToolProblem("\(job.handle) could not record its end: \(error)")))
          Self.execLog.warning("\(job.handle) could not record its end: \(error)")
        }
      })
    } catch is CancellationError {
      execJobs.finish(job, .problem(ToolProblem("the server stopped while \(job.handle) ran; it is followed again when it starts")))
    } catch {
      execJobs.finish(job, .problem(ToolProblem("\(job.handle) could not record its end: \(error)")))
    }
  }

  func settle(_ job: ExecJob, _ outcome: ExecJob.Outcome) async throws {
    try await job.gate.holding {
      switch job.phase {
      case .awaited, .detaching:
        // Keep the job until the loop commits, so its result can carry the ack.
        job.ended.fulfill(outcome)
      case .detached:
        try await settleDetached(job, outcome)
      case .cancelled:
        try? await delivered(job)
        execJobs.finish(job, outcome)
        job.committed.fulfill(true)
      case .released:
        execJobs.finish(job, outcome)
        job.committed.fulfill(false)
      }
    }
  }

  private func settleDetached(_ job: ExecJob, _ outcome: ExecJob.Outcome) async throws {
    do {
      _ = try await owner.append(job.session, .inputEnqueued(.notification(notice(job, outcome))))
    } catch let error as SessionStoreError {
      try? await delivered(job)
      execJobs.finish(job, outcome)
      job.committed.fulfill(true)
      throw error
    }
    try await delivered(job)
    execJobs.finish(job, outcome)
    job.committed.fulfill(true)
  }

  func execCommitted(_ session: SessionID, _ call: ToolCallID) -> (@Sendable () async -> Void)? {
    guard let job = execJobs.job(session, call) else { return nil }
    switch job.phase {
    case .detaching:
      return {
        do {
          try await job.gate.holding {
            guard job.phase == .detaching else { return }
            job.phase = .detached
            if let outcome = job.ended.value { try await self.settleDetached(job, outcome) }
          }
        } catch {
          self.execJobs.remove(job)
          job.committed.fulfill(false)
          Self.execLog.warning("\(job.handle) could not record its end: \(error)")
        }
      }
    case .awaited where job.ended.value != nil:
      return {
        do {
          try await self.delivered(job)
          self.execJobs.remove(job)
          job.committed.fulfill(true)
        } catch {
          self.execJobs.remove(job)
          job.committed.fulfill(false)
          Self.execLog.warning("\(job.handle) could not record delivery of its end: \(error)")
        }
      }
    case .awaited, .detached, .cancelled, .released:
      return nil
    }
  }

  func delivered(_ job: ExecJob) async throws {
    if job.deliveryRecorded.value == true { return }
    let client = try await client(job.session)
    let _: ExecJobReply = try await client.api(.post, "/v1/exec/\(job.id.rawValue)/delivered")
    job.deliveryRecorded.fulfill(true)
  }

  private func notice(_ job: ExecJob, _ outcome: ExecJob.Outcome) -> SystemNotification {
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

  private func outcome(of drive: DriveOutcome, job: ExecJob, spec: ExecJobSpec, client: SpaceClient) async -> ExecJob.Outcome {
    let record: ExecStatus? = try? await client.api(.get, "/v1/exec/\(job.id.rawValue)")
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
      let maxOutput = spec.maxOutput
      if output.count >= maxOutput {
        text += "\n[output hit the \(maxOutput)-byte budget; the command was killed]"
      }
      if timedOut == .killed {
        text += spec.defaultLifetime
          ? "\n[killed after \(seconds(.seconds(spec.lifetime))) s, the default max lifetime; start longer work detached and watch it from run_script]"
          : "\n[killed after \(seconds(.seconds(spec.lifetime))) s, its max_lifetime_seconds]"
      }
      return .payload(.exec(.init(output: text, exitCode: exitCode, reaped: record?.state == .reaped)))
    case let .lost(message):
      return switch record?.state {
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
}

extension ExecJob.Outcome {
  func result() throws -> ToolResultPayload {
    switch self {
    case let .payload(payload): payload
    case let .problem(problem): throw problem
    }
  }
}

private actor ExecBuffer {
  var bytes: [UInt8] = []
  var cut = false
  var timedOut: ExecTimeout?

  func received(_ chunk: [UInt8]) { bytes += chunk }
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

private struct ExecJobReply: Decodable {}
