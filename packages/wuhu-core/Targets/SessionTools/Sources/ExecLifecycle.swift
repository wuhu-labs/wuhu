import Dependencies
import Logging
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct MachineContract.ExecID
import struct MachineContract.ExecStatus
import func MainHub.execHandle
import struct MainHub.ToolProblem
import SessionDomain
import SpaceClient
import SpaceCore

extension ToolExecutor {
  private func ownExec(_ id: ExecID, session: SessionID) async throws -> ExecStatus? {
    do {
      return try await client(session).api(.get, "/v1/exec/\(id.rawValue)")
    } catch let error as SpaceClient.TransportFailure where error.code == "notFound" { return nil }
    catch let error as SpaceClient.ToolFailure where error.error.code.rawValue == "notFound" { return nil }
  }

  private func killExec(_ id: ExecID, client: SpaceClient) async throws {
    do {
      let _: EmptyExecReply = try await client.api(.post, "/v1/exec/\(id.rawValue)/kill")
    } catch let failure as SpaceClient.ToolFailure where failure.error.code.rawValue == "alreadyEnded" {
      throw ToolProblem("\(execHandle(id)) has already ended", code: "alreadyEnded")
    } catch let failure as SpaceClient.TransportFailure where failure.code == "alreadyEnded" {
      throw ToolProblem("\(execHandle(id)) has already ended", code: "alreadyEnded")
    }
  }

  public func killInterrupted(session: SessionID, callID: ToolCallID) async {
    if let job = execJobs.job(session, callID) {
      let interrupted = try? await job.gate.holding { () -> Bool in
        guard job.phase != .detached, job.phase != .detaching else { return false }
        job.phase = .cancelled
        try? await delivered(job)
        if job.ended.value != nil {
          execJobs.remove(job)
          job.committed.fulfill(job.deliveryRecorded.value == true)
        }
        return true
      }
      guard interrupted == true, let client = try? await client(session) else { return }
      try? await killExec(job.id, client: client)
      return
    }
    guard let client = try? await client(session),
          let records: [ExecStatus] = try? await client.api(.get, "/v1/exec"),
          let record = records.first(where: { $0.toolCallID == callID.rawValue && $0.state == .live }) else { return }
    try? await killExec(record.id, client: client)
  }

  /// cancel(exec.…): SIGTERM to the process group, SIGKILL 5 s later. The
  /// end is not announced; the result says how it ended, if it does soon.
  func cancelExec(_ session: SessionID, _ id: ExecID) async throws -> ToolResultPayload {
    let handle = execHandle(id)
    let job = execJobs.job(session, exec: id)
    if job == nil {
      guard let record = try await ownExec(id, session: session), record.toolCallID != nil else {
        throw ToolProblem("you have no exec \(handle)", code: "notFound")
      }
      guard record.state == .live else { throw ToolProblem("\(handle) has already ended", code: "alreadyEnded") }
    }
    let client = try await client(session)
    guard let job else {
      try await killExec(id, client: client)
      let _: EmptyExecReply = try await client.api(.post, "/v1/exec/\(id.rawValue)/delivered")
      return .script(.init(output: "\(handle) was sent SIGTERM to its process group, and gets SIGKILL 5 s later"))
    }
    try await job.gate.holding {
      guard job.ended.value == nil else { throw ToolProblem("\(handle) has already ended", code: "alreadyEnded") }
      let phase = job.phase
      let detached = phase != .awaited
      if detached { job.phase = .cancelled }
      do { try await killExec(id, client: client) }
      catch {
        if detached { job.phase = phase }
        throw error
      }
      if detached { try await delivered(job) }
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

  public func cancelExecJobs(of session: SessionID) async {
    guard let client = try? await client(session) else { return }
    for job in execJobs.jobs(of: session) {
      try? await job.gate.holding {
        job.phase = .cancelled
        try? await delivered(job)
        if job.ended.value != nil {
          execJobs.remove(job)
          job.committed.fulfill(job.deliveryRecorded.value == true)
        }
      }
      try? await killExec(job.id, client: client)
    }
  }

  public func runningExecJobs(of session: SessionID) -> [String] { execJobs.running(of: session) }

  public func adoptExecJobs() async {
    let records: [ExecRecord]
    do { records = try await owner.owedExecs() } catch {
      Self.execLog.error("could not read the exec jobs a restart interrupted: \(error)")
      return
    }
    for record in records {
      guard let caller = record.caller, let call = record.toolCallID else { continue }
      let session = SessionID(rawValue: caller)
      guard execJobs.job(session, call) == nil else { continue }
      do {
        let hydration = try await owner.hydrate(session)
        if case let .kernel(transcript) = hydration.transcript, transcript.pendingToolCallIDs.contains(call) { continue }
      } catch {
        Self.execLog.warning("could not read the exec caller's transcript: \(error)")
      }
      let job = ExecJob(
        session: session,
        call: call,
        id: record.id,
        startedAt: record.startedAt,
        notice: UUID.deterministic("exec-end", session.rawValue, call.rawValue),
        spec: record.toolSpec ?? "",
        phase: .detached,
        adopted: true,
      )
      guard let encoded = record.toolSpec,
            let spec = try? JSONDecoder().decode(ExecJobSpec.self, from: Data(encoded.utf8)),
            let client = try? await client(session)
      else {
        do { try await settle(job, .problem(ToolProblem("this server cannot rejoin it"))) }
        catch { Self.execLog.error("\(job.handle) could not deliver its end: \(error)") }
        continue
      }
      execJobs.insert(job)
      do { try drive(job, spec: spec, client: client) }
      catch { Self.execLog.warning("\(job.handle) was not re-adopted: \(error.message)") }
    }
  }
}

private struct EmptyExecReply: Decodable {}
