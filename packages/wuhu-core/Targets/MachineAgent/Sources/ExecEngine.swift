import Logging
import MachineChannel
import MachineContract
import Subprocess
import Synchronization

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

#if canImport(System)
  import System
#else
  import SystemPackage
#endif

private typealias ChildProcess = Execution<CustomWriteInput, SequenceOutput, SequenceOutput>

struct ExecEngine: Sendable {
  let registry: ExecRegistry
  let clock: any Clock<Duration>
  let killGrace: Duration
  let logger: Logger

  /// The server's names, set last so nothing the caller sent can shadow them.
  /// Without a session they are removed, so a process never inherits the
  /// agent's own.
  static func sessionEnvironment(_ session: ExecSessionCredential?) -> [String: String?] {
    guard let session else {
      return Dictionary(uniqueKeysWithValues: SessionExecEnvironment.reserved.map { ($0, String?.none) })
    }
    return [
      SessionExecEnvironment.exec: "1",
      SessionExecEnvironment.token: session.token,
      SessionExecEnvironment.spaceURL: session.spaceURL,
      SessionExecEnvironment.expiresAt: String?.none,
    ]
  }

  /// What the exec's environment changes from the agent's own, a nil value
  /// unsetting the name: an inherited `WUHU_IDENTITY` or `WUHU_GROUP` is
  /// dropped unless the start itself sets it, so an agent launched in wallet
  /// mode or in a group never puts its execs there; then `env`, the resolved
  /// secrets and the session names, rightmost wins.
  static func environmentOverlay(_ start: ExecStart) -> [String: String?] {
    var overlay: [String: String?] = [
      SessionExecEnvironment.identity: String?.none,
      SessionExecEnvironment.group: String?.none,
    ]
    for (name, value) in start.env?.entries ?? [:] { overlay[name] = .some(value) }
    for (name, value) in start.secretValues?.entries ?? [:] { overlay[name] = .some(value) }
    for (name, value) in sessionEnvironment(start.session) { overlay[name] = .some(value) }
    return overlay
  }

  /// What the exec can leak, masked in its output: the injected secret values
  /// and the session token. An empty value would mask every position, so it
  /// is injected but not masked.
  static func maskedValues(_ start: ExecStart) -> [String] {
    let values = (start.secretValues.map { Array($0.entries.values) } ?? []) + [start.session?.token].compactMap(\.self)
    return Set(values).filter { !$0.isEmpty }.sorted()
  }

  func run(_ exec: IncomingExec) async {
    let start = exec.start
    // Only a server from before group secrets sends names: this agent keeps
    // no values to resolve them from.
    if let name = start.secrets?.entries.values.min() {
      await fail(exec, "secret \(name) came as a name, not a value; this machine's server predates group secrets")
      return
    }
    guard let executable = start.command.first, !executable.isEmpty else {
      await fail(exec, "empty command")
      return
    }

    var overlay: [Environment.Key: String?] = [:]
    for (name, value) in Self.environmentOverlay(start) {
      overlay[Environment.Key(stringLiteral: name)] = value
    }
    let masked = Self.maskedValues(start)

    var options = PlatformOptions()
    options.processGroupID = 0
    options.teardownSequence = [.send(signal: .terminate, toProcessGroup: true, allowedDurationToNextStep: killGrace)]

    let agentKills = registry.register(start.id)
    defer { registry.unregister(start.id) }
    let timedOut = TimeoutMark()

    do {
      let result = try await withThrowingTaskGroup(of: Void.self) { group in
        let (executions, executionContinuation) = AsyncStream<ChildProcess>.makeStream()
        let (kills, killContinuation) = AsyncStream<Void>.makeStream()
        defer {
          executionContinuation.finish()
          killContinuation.finish()
          group.cancelAll()
        }
        group.addTask {
          for await execution in executions {
            await supervise(exec, execution, agentKills: agentKills, kills: kills, kill: killContinuation, timedOut: timedOut)
          }
        }
        let outcome = try await Subprocess.run(
          executable.contains("/") ? .path(FilePath(executable)) : .name(executable),
          arguments: Arguments(Array(start.command.dropFirst())),
          environment: .inherit.updating(overlay),
          workingDirectory: FilePath(start.cwd),
          platformOptions: options,
          input: .inputWriter,
          output: .sequence,
          error: .sequence,
        ) { execution in
          executionContinuation.yield(execution)
          await pump(exec, execution, secrets: masked, kill: killContinuation)
        }
        executionContinuation.finish()
        killContinuation.finish()
        try await group.waitForAll()
        return outcome
      }
      await exec.exit(status(of: result.terminationStatus), timedOut: timedOut.won.withLock { $0 } ? .killed : nil)
    } catch is CancellationError {
      return
    } catch {
      await fail(exec, "spawn failed: \(error)")
    }
  }

  private func supervise(
    _ exec: IncomingExec,
    _ execution: ChildProcess,
    agentKills: AsyncStream<Void>,
    kills: AsyncStream<Void>,
    kill: AsyncStream<Void>.Continuation,
    timedOut: TimeoutMark,
  ) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        for await _ in exec.kills { kill.yield(()) }
      }
      group.addTask {
        for await _ in agentKills { kill.yield(()) }
      }
      if let timeout = exec.start.timeout {
        group.addTask {
          do { try await clock.sleep(for: .seconds(min(timeout, execTimeoutCeiling))) } catch { return }
          timedOut.due.withLock { $0 = true }
          kill.yield(())
        }
      }
      var iterator = kills.makeAsyncIterator()
      if await iterator.next() != nil, !Task.isCancelled {
        await exec.stopOutput()
        // Checked as late as possible: a command that exited on its own as
        // the timeout fired keeps its own exit, without the timeout's mark.
        if timedOut.due.withLock({ $0 }), !exited(execution) { timedOut.won.withLock { $0 = true } }
        try? execution.send(signal: .terminate, toProcessGroup: true)
        do {
          try await clock.sleep(for: killGrace)
          try Task.checkCancellation()
          try? execution.send(signal: .kill, toProcessGroup: true)
        } catch {}
      }
      group.cancelAll()
    }
  }

  private func pump(
    _ exec: IncomingExec,
    _ execution: ChildProcess,
    secrets: [String],
    kill: AsyncStream<Void>.Continuation,
  ) async {
    let budget = OutputBudget(limit: exec.start.maxOutput)
    let queue = ExecOutputQueue(exec)
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        do {
          for try await chunk in exec.stdin {
            _ = try await execution.standardInputWriter.write(chunk)
          }
          try await execution.standardInputWriter.finish()
        } catch {}
      }
      await withTaskGroup(of: Void.self) { pumps in
        pumps.addTask {
          await relay(execution.standardOutput, as: .stdout, exec: exec, secrets: secrets, budget: budget, queue: queue, kill: kill)
        }
        pumps.addTask {
          await relay(execution.standardError, as: .stderr, exec: exec, secrets: secrets, budget: budget, queue: queue, kill: kill)
        }
      }
      group.cancelAll()
    }
  }

  /// With a budget, the pipe is read on while a send waits for window: the budget sees an overrun even when the caller is not
  /// reading. The read-ahead is an `ExecOutputQueue`; a budget above its ceiling, or none, makes each send hold the pipe.
  private func relay(
    _ output: SubprocessOutputSequence,
    as stream: ExecOutputStream,
    exec: IncomingExec,
    secrets: [String],
    budget: OutputBudget,
    queue: ExecOutputQueue?,
    kill: AsyncStream<Void>.Continuation,
  ) async {
    await withTaskGroup(of: Void.self) { group in
      if let queue {
        // The kill comes after both queues have drained: killing stops the output.
        group.addTask { if (try? await queue.run(stream)) == true { kill.yield(()) } }
      }
      var masker = SecretMasker(secrets: secrets)
      do {
        for try await buffer in output {
          let bytes = buffer.withUnsafeBytes { Array($0) }
          try await forward(masker.mask(bytes), as: stream, exec: exec, budget: budget, queue: queue, kill: kill)
        }
      } catch {}
      try? await forward(masker.flush(), as: stream, exec: exec, budget: budget, queue: queue, kill: kill)
      queue?.finish(stream)
    }
  }

  private func forward(
    _ masked: [UInt8],
    as stream: ExecOutputStream,
    exec: IncomingExec,
    budget: OutputBudget,
    queue: ExecOutputQueue?,
    kill: AsyncStream<Void>.Continuation,
  ) async throws {
    guard !masked.isEmpty else { return }
    let (allowed, exceeded) = budget.admit(masked)
    if let queue {
      queue.enqueue(allowed, to: stream)
      if exceeded { await queue.overrun() }
      return
    }
    if !allowed.isEmpty {
      try await exec.send(stream, allowed, waitForCapacity: !exceeded)
    }
    if exceeded {
      await exec.stopOutput()
      kill.yield(())
    }
  }

  private func fail(_ exec: IncomingExec, _ message: String) async {
    try? await exec.send(.stderr, Array("wuhu: \(message)\n".utf8))
    await exec.exit(.exited(code: 127))
  }

  private func status(of termination: TerminationStatus) -> ExitStatus {
    switch termination {
    case let .exited(code): .exited(code: Int(code))
    case let .signaled(signal): .signaled(signal: Int(signal))
    }
  }
}

final class ExecRegistry: Sendable {
  private let continuations = Mutex<[ExecID: AsyncStream<Void>.Continuation]>([:])

  func register(_ id: ExecID) -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    continuations.withLock { $0[id] = continuation }
    return stream
  }

  func unregister(_ id: ExecID) {
    continuations.withLock { $0.removeValue(forKey: id) }?.finish()
  }

  func killAll() {
    for continuation in continuations.withLock({ Array($0.values) }) {
      continuation.yield(())
    }
  }
}

final class OutputBudget: Sendable {
  private let remaining: Mutex<Int?>

  init(limit: Int?) {
    remaining = Mutex(limit)
  }

  func admit(_ bytes: [UInt8]) -> (allowed: [UInt8], exceeded: Bool) {
    remaining.withLock { remaining in
      guard let room = remaining else { return (bytes, false) }
      if bytes.count <= room {
        remaining = room - bytes.count
        return (bytes, false)
      }
      remaining = 0
      return (Array(bytes.prefix(room)), true)
    }
  }
}

// Seconds. A caller's timeout is clamped here, for every caller: about 31
// years, far inside what Duration and a clock's sleep can hold (a larger
// value trapped the agent).
let execTimeoutCeiling = 1e9

private final class TimeoutMark: Sendable {
  /// The timeout asked for the kill.
  let due = Mutex(false)
  /// The timeout's kill reached the command before it exited on its own.
  let won = Mutex(false)
}

/// Whether the command has exited, its zombie left for Subprocess to reap.
private func exited(_ execution: ChildProcess) -> Bool {
  var info = siginfo_t()
  while waitid(P_PID, id_t(execution.processIdentifier.value), &info, WEXITED | WNOHANG | WNOWAIT) == -1 {
    guard errno == EINTR else { return true }
  }
  return info.si_signo != 0
}
