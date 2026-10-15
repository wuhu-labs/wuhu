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
import class ComputerFiles.ComputerAgent
import struct ComputerFiles.ComputerFileSystem
import struct ComputerFiles.ExternalKind
import Fetch
import FetchAsyncHTTPClient
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationError
import struct OperationRuntime.AnyOperationKind
import typealias Serve.Handler
import class ServeNIO.ServeNIOServer

extension ExecSupervisor {
  public static func runComputerAgent(
    machine: String,
    operationsDirectory: String,
    controlSocket: String,
    executable: String,
    serve: @escaping @Sendable (@escaping Handler, @escaping @Sendable () async -> Bool) async throws -> Void,
  ) async throws {
    guard controlSocket.hasPrefix("/"), controlSocket.utf8.count < 104 else { throw OperationError(.invalidConfiguration) }
    var state = stat()
    let parent = URL(fileURLWithPath: controlSocket).deletingLastPathComponent().path
    guard lstat(parent, &state) == 0, state.st_uid == getuid(), state.st_mode & 0o777 == 0o700 else { throw OperationError(.invalidConfiguration) }
    try await withComputerAgent(machine: machine, operationsDirectory: operationsDirectory, executable: executable) { agent in
      var state = stat()
      if lstat(controlSocket, &state) == 0 {
        guard state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFSOCK, unlink(controlSocket) == 0 else { throw OperationError(.invalidConfiguration) }
      }
      let server = try await ServeNIOServer.bind(unixDomainSocketPath: controlSocket, handler: agent.controlHandler)
      guard chmod(controlSocket, 0o600) == 0 else { await server.shutdown(); throw OperationError(.invalidConfiguration) }
      defer { _ = unlink(controlSocket) }
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { await server.runUntilCancelled() }
          group.addTask { try await serve(agent.handler, { await agent.leaveAcknowledged }) }
          do { _ = try await group.next() }
          catch { await server.shutdown(); group.cancelAll(); throw error }
          await server.shutdown(); group.cancelAll()
        }
      } catch { await server.shutdown(); throw error }
    }
  }

  /// Holds the exclusive lock on `operationsDirectory`, recovers its supervisors and runs the composed agent for the duration of `body`. The caller serves `agent.handler` and calls `agent.leave()` itself; no control socket is opened.
  public static func withComputerAgent<R: Sendable>(
    machine: String,
    operationsDirectory: String,
    executable: String,
    files: ComputerFileSystem = .local,
    kinds: [AnyOperationKind] = [],
    _ body: @escaping @Sendable (ComputerAgent) async throws -> R,
  ) async throws -> R {
    try await composeComputerAgent(machine: machine, operationsDirectory: operationsDirectory, executable: executable, files: files, kinds: kinds) { agent, _ in try await body(agent) }
  }

  /// The composition itself; tests also get the registry to observe its run loop.
  static func composeComputerAgent<R: Sendable>(
    machine: String,
    operationsDirectory: String,
    executable: String,
    files: ComputerFileSystem,
    kinds: [AnyOperationKind],
    _ body: @escaping @Sendable (ComputerAgent, ExecSupervisorRegistry) async throws -> R,
  ) async throws -> R {
    let lock = exec_lock_agent(operationsDirectory)
    guard lock >= 0 else { throw OperationError(.invalidConfiguration, message: "Another agent owns this v2 home") }
    defer { exec_close(lock) }
    return try await withUnixHTTP { http in
      let registry = try ExecSupervisorRegistry(machine: machine, operationsDirectory: operationsDirectory, executable: executable, fetch: .asyncHTTPClient(http, timeout: .seconds(25)), identityFetch: .asyncHTTPClient(http, timeout: .seconds(2)), authorize: { _, id in
        guard id == machine else { throw OperationError(.machineNotAuthorized) }
      })
      try await registry.recover()
      let agent = try ComputerAgent(machine: machine, files: files, kinds: kinds, external: registry.external)
      return try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { await registry.run() }
        group.addTask { await agent.run() }
        do {
          let result = try await body(agent, registry)
          await agent.shutdown(); group.cancelAll()
          return result
        } catch { await agent.shutdown(); group.cancelAll(); throw error }
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

extension ComputerAgent {
  nonisolated var controlHandler: Handler {
    { request in
      do {
        guard request.method == .put, request.url.path == "/leave" else { throw OperationError(.invalidInput) }
        try await self.leave()
        return try .json(true)
      } catch {
        let error = error as? OperationError ?? .init(.supervisorUnavailable)
        return try! .json(ErrorEnvelope(error), status: .init(code: error.statusCode))
      }
    }
  }
}
