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
import class AsyncHTTPClient.HTTPClient
import CExecSupervisor
import struct ComputerFiles.AdmittedStart
import class ComputerFiles.ComputerAgent
import struct ComputerFiles.ComputerFileSystem
import struct ComputerFiles.ExternalKind
import Fetch
import FetchAsyncHTTPClient
import struct Logging.Logger
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationError
import struct OperationRuntime.AnyOperationKind
import typealias Serve.Handler
import class ServeNIO.ServeNIOServer
import Synchronization

/// Why an agent stops serving its machine. Either way every exec supervisor it owns is retired: its exec stops, its receipts go and it exits.
public enum SupervisorRetirement: Sendable, Equatable {
  /// The person or the app turned the machine off. The machine's private directory stays, so turning it back on resumes.
  case turnedOff
  /// The server revoked the machine's key or no longer knows the machine. With ``ExecSupervisor/withComputerAgent(machine:operationsDirectory:executable:files:kinds:audit:_:)``,
  /// the machine's private directory, the parent of the operations directory, is removed once the agent stops. The installed agent
  /// keeps its home, which holds its key, configuration and executable, until it is uninstalled.
  case revoked
}

extension ExecSupervisor {
  /// Runs the installed agent. `serve` gets the agent's handler, whether the server acknowledged a leave, and `retire`, which the
  /// caller invokes when the server says the machine is revoked or unknown. A successful local leave retires the supervisors as a turn-off.
  public static func runComputerAgent(
    machine: String,
    operationsDirectory: String,
    controlSocket: String,
    executable: String,
    serve: @escaping @Sendable (@escaping Handler, @escaping @Sendable () async -> Bool, @escaping @Sendable (SupervisorRetirement) async -> Void) async throws -> Void,
  ) async throws {
    guard controlSocket.hasPrefix("/"), controlSocket.utf8.count < 104 else { throw OperationError(.invalidConfiguration) }
    var state = stat()
    let parent = URL(fileURLWithPath: controlSocket).deletingLastPathComponent().path
    guard lstat(parent, &state) == 0, state.st_uid == getuid(), state.st_mode & 0o777 == 0o700 else { throw OperationError(.invalidConfiguration) }
    try await composeComputerAgent(machine: machine, operationsDirectory: operationsDirectory, executable: executable, files: .local, kinds: [], disclaimResponsibility: boxAgentDisclaimsResponsibility()) { agent, registry in
      var state = stat()
      if lstat(controlSocket, &state) == 0 {
        guard state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFSOCK, unlink(controlSocket) == 0 else { throw OperationError(.invalidConfiguration) }
      }
      let server = try await ServeNIOServer.bind(unixDomainSocketPath: controlSocket, handler: agent.controlHandler(afterLeave: { _ = await registry.retire(.turnedOff) }))
      guard chmod(controlSocket, 0o600) == 0 else { await server.shutdown(); throw OperationError(.invalidConfiguration) }
      defer { _ = unlink(controlSocket) }
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { await server.runUntilCancelled() }
          group.addTask { try await serve(agent.handler, { await agent.leaveAcknowledged }, { _ = await registry.retire($0) }) }
          do { _ = try await group.next() }
          catch { await server.shutdown(); group.cancelAll(); throw error }
          await server.shutdown(); group.cancelAll()
        }
      } catch { await server.shutdown(); throw error }
    }
  }

  /// Holds the exclusive lock on `operationsDirectory`, recovers its supervisors and runs the composed agent for the duration of `body`. The caller serves `agent.handler` and calls `agent.leave()` itself; no control socket is opened.
  ///
  /// When the machine stops serving, the body calls the second argument, `retire`, before it returns. It waits at most ten seconds for the supervisors to exit.
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
    try await composeComputerAgent(machine: machine, operationsDirectory: operationsDirectory, executable: executable, files: files, kinds: kinds, audit: audit, forgetsRevokedMachine: true) { agent, registry in
      try await body(agent, { _ = await registry.retire($0) })
    }
  }

  /// The composition itself; tests also get the registry to observe its run loop.
  static func composeComputerAgent<R: Sendable>(
    machine: String,
    operationsDirectory: String,
    executable: String,
    files: ComputerFileSystem,
    kinds: [AnyOperationKind],
    audit: (@Sendable (AdmittedStart) -> Void)? = nil,
    disclaimResponsibility: Bool = false,
    forgetsRevokedMachine: Bool = false,
    _ body: @escaping @Sendable (ComputerAgent, ExecSupervisorRegistry) async throws -> R,
  ) async throws -> R {
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
    return try await withUnixHTTP { http, events in
      let registry = try ExecSupervisorRegistry(machine: machine, operationsDirectory: operationsDirectory, executable: executable, fetch: .asyncHTTPClient(http, timeout: .seconds(25)), identityFetch: .asyncHTTPClient(http, timeout: .seconds(2)), disclaimResponsibility: disclaimResponsibility, authorize: { _, id in
        guard id == machine else { throw OperationError(.machineNotAuthorized) }
      })
      try await registry.recover()
      // Holding the lock entitles this agent to replace a stale ctl.sock; supervisors that outlived the last agent redial it.
      let listener = try await Rendezvous.listen(path: rendezvous, group: events)
      defer { _ = unlink(rendezvous) }
      let agent = try ComputerAgent(machine: machine, files: files, kinds: kinds, external: registry.external, audit: audit)
      return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await registry.run() }
        group.addTask { await agent.run() }
        group.addTask { await Rendezvous.accept(listener, registry: registry) }
        let outcome: Result<R, any Error>
        do { outcome = .success(try await body(agent, registry)) } catch { outcome = .failure(error) }
        await agent.shutdown(); group.cancelAll()
        if await registry.retirement == .revoked { revoked.withLock { $0 = true } }
        return try outcome.get()
      }
    }
  }
}

extension ExecSupervisorRegistry {
  nonisolated var external: ExternalKind {
    ExternalKind(
      descriptor: ComputerKindSchemas.exec,
      reservation: Self.fullReservation,
      handler: handler,
      usage: { try await self.admissionUsage() },
      owns: { await self.owns($0) },
      leave: { try await self.leave() },
      departure: { try await self.departureEvidence() },
    )
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

extension ComputerAgent {
  nonisolated var controlHandler: Handler { controlHandler(afterLeave: {}) }

  /// `PUT /leave`; `afterLeave` runs once the leave has succeeded, before the reply.
  nonisolated func controlHandler(afterLeave: @escaping @Sendable () async -> Void) -> Handler {
    { request in
      do {
        guard request.method == .put, request.url.path == "/leave" else { throw OperationError(.invalidInput) }
        try await self.leave()
        await afterLeave()
        return try .json(true)
      } catch {
        let error = error as? OperationError ?? .init(.supervisorUnavailable)
        return try! .json(ErrorEnvelope(error), status: .init(code: error.statusCode))
      }
    }
  }
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
