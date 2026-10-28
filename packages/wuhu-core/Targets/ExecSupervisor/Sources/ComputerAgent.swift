#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import CExecSupervisor
import struct ComputerFiles.AdmittedStart
import class ComputerFiles.ComputerAgent
import struct ComputerFiles.ComputerFileSystem
import struct ComputerFiles.ExternalKind
import DeploymentAdmin
import Fetch
import struct Logging.Logger
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.OperationError
import struct OperationRuntime.AnyOperationKind
import class OperationRuntime.OperationAgent
import typealias Serve.Handler
import Synchronization

/// Why an agent stops serving its machine. Either way every running exec is stopped and every adopted supervisor retired; each worker exits once its receipts lapse.
public enum SupervisorRetirement: Sendable, Equatable {
  /// The person or the app turned the machine off. The machine's private directory stays, so turning it back on resumes.
  case turnedOff
  /// The server revoked the machine's key or no longer knows the machine. With ``ExecSupervisor/withComputerAgent(machine:operationsDirectory:executable:files:kinds:audit:_:)``,
  /// the machine's private directory, the parent of the operations directory, is removed once the agent stops. The installed agent
  /// keeps its home, which holds its key, configuration and executable, until it is uninstalled.
  case revoked
}

extension ExecSupervisor {
  public static func runComputerAgent(
    machine: String,
    operationsDirectory: String,
    executable: String,
    serve: @escaping @Sendable (@escaping Handler, @escaping @Sendable (SupervisorRetirement) async -> Void) async throws -> Void,
  ) async throws {
    try await composeComputerAgent(machine: machine, operationsDirectory: operationsDirectory, executable: executable, files: .local, kinds: [], disclaimResponsibility: boxAgentDisclaimsResponsibility()) { agent, workers in
      try await serve(agent.handler, { _ = await workers.retire($0) })
    }
  }

  /// Holds the exclusive lock on `operationsDirectory`, recovers its exec workers and runs the composed agent for the duration of `body`. The caller serves `agent.handler`; no control socket is opened.
  ///
  /// When the machine stops serving, the body calls the second argument, `retire`, before it returns. It waits at most ten seconds for the stopped execs' verdicts.
  /// After a revocation the machine's private directory, the parent of `operationsDirectory`, is removed once the lock is released.
  public static func withComputerAgent<R: Sendable>(
    machine: String,
    operationsDirectory: String,
    executable: String,
    files: ComputerFileSystem = .local,
    kinds: [AnyOperationKind] = [],
    audit: (@Sendable (AdmittedStart) -> Void)? = nil,
    _ body: @escaping @Sendable (ComputerAgent, _ retire: @escaping @Sendable (SupervisorRetirement) async -> Void) async throws -> R,
  ) async throws -> R {
    try await composeComputerAgent(machine: machine, operationsDirectory: operationsDirectory, executable: executable, files: files, kinds: kinds, audit: audit, forgetsRevokedMachine: true) { agent, workers in
      try await body(agent, { _ = await workers.retire($0) })
    }
  }

  /// The composition itself; tests also get the workers to observe them.
  static func composeComputerAgent<R: Sendable>(
    machine: String,
    operationsDirectory: String,
    executable: String,
    files: ComputerFileSystem,
    kinds: [AnyOperationKind],
    audit: (@Sendable (AdmittedStart) -> Void)? = nil,
    disclaimResponsibility: Bool = false,
    forgetsRevokedMachine: Bool = false,
    retention: Duration = OperationAgent.receiptRetention,
    launch: (@Sendable ([String]) async throws -> Int32?)? = nil,
    _ body: @escaping @Sendable (ComputerAgent, ExecWorkers) async throws -> R,
  ) async throws -> R {
    let admission = try DeploymentAdminPolicy.admitMachineAgent()
    defer { withExtendedLifetime(admission) {} }
    // A path the platform cannot bind is a typed refusal to start, before anything else happens.
    let rendezvous = Rendezvous.socketPath(operationsDirectory: operationsDirectory)
    try Rendezvous.validateSocketPath(rendezvous)
    // Runs after the lock is released and every socket is closed.
    let revoked = Mutex(false)
    defer { if forgetsRevokedMachine, revoked.withLock({ $0 }) { removeMachineDirectory(operationsDirectory: operationsDirectory) } }
    let lock = exec_lock_agent(operationsDirectory)
    guard lock >= 0 else { throw OperationError(.invalidConfiguration, message: "Another agent owns this v2 home") }
    defer {
      _ = flock(lock, LOCK_UN)
      exec_close(lock)
    }
    return try await withEventLoop { events in
      let workers = try ExecWorkers(machine: machine, operationsDirectory: operationsDirectory, executable: executable, disclaimResponsibility: disclaimResponsibility, retention: retention, launch: launch ?? { try ExecSupervisor.launchReaped($0) }, authorize: { _, id in
        guard id == machine else { throw OperationError(.machineNotAuthorized) }
      })
      try await workers.recover()
      // Holding the lock entitles this agent to replace a stale ctl.sock; workers that outlived the last agent redial it.
      let listener = try await Rendezvous.listen(path: rendezvous, group: events)
      defer { _ = unlink(rendezvous) }
      let agent = try ComputerAgent(machine: machine, files: files, kinds: kinds, external: workers.external, audit: audit)
      return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await workers.run() }
        group.addTask { await agent.run() }
        group.addTask { await Rendezvous.accept(listener, workers: workers) }
        let outcome: Result<R, any Error>
        do { outcome = .success(try await body(agent, workers)) } catch { outcome = .failure(error) }
        await agent.shutdown(); group.cancelAll()
        if await workers.service == .retired(.revoked) { revoked.withLock { $0 = true } }
        return try outcome.get()
      }
    }
  }
}

/// Removes a revoked machine's private directory, the parent of `operationsDirectory`, only when it is this user's owner-private
/// directory: a shared parent such as `/tmp` is never removed.
func removeMachineDirectory(operationsDirectory: String) {
  let directory = Rendezvous.machineDirectory(operationsDirectory: operationsDirectory)
  var state = stat()
  guard directory != "/", lstat(directory, &state) == 0, state.st_mode & S_IFMT == S_IFDIR, state.st_uid == getuid(), state.st_mode & 0o077 == 0 else { return }
  try? FileManager.default.removeItem(atPath: directory)
}

func boxAgentDisclaimsResponsibility(
  available: Bool = exec_disclaim_responsibility_available() != 0,
  reportUnavailable: () -> Void = { Logger(label: "machine-v2").warning("tccDisclaim: unavailable; exec children inherit TCC responsibility") },
) -> Bool {
  #if os(macOS)
    if !available { reportUnavailable() }
    return available
  #else
    return false
  #endif
}
