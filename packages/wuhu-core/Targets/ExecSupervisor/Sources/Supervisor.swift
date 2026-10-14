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
import Fetch
import FetchAsyncHTTPClient
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import struct OperationRuntime.AnyOperationKind
import class OperationRuntime.OperationAgent
import typealias Serve.Handler
import class ServeNIO.ServeNIOServer

public enum ExecSupervisor {
  public static func runLocalAgent(machine: String, operationsDirectory: String, socket: String, executable: String) async throws {
    guard socket.hasPrefix("/"), socket.utf8.count < 104 else { throw OperationError(.invalidConfiguration) }
    var state = stat()
    let parent = URL(fileURLWithPath: socket).deletingLastPathComponent().path
    guard lstat(parent, &state) == 0, state.st_uid == getuid(), state.st_mode & 0o777 == 0o700 else { throw OperationError(.invalidConfiguration) }
    let lock = exec_lock_agent(operationsDirectory)
    guard lock >= 0 else { throw OperationError(.invalidConfiguration, message: "Another agent owns this operations directory or its lock is not private") }
    defer { exec_close(lock) }
    if lstat(socket, &state) == 0 {
      guard state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFSOCK else { throw OperationError(.invalidConfiguration) }
      guard unlink(socket) == 0 else { throw OperationError(.invalidConfiguration) }
    }
    var configuration = HTTPClient.Configuration()
    configuration.redirectConfiguration = .disallow
    let http = HTTPClient(eventLoopGroupProvider: .singleton, configuration: configuration)
    do {
      let registry = try ExecSupervisorRegistry(
        machine: machine,
        operationsDirectory: operationsDirectory,
        executable: executable,
        fetch: .asyncHTTPClient(http, timeout: .seconds(25)),
        identityFetch: .asyncHTTPClient(http, timeout: .seconds(2)),
        authorize: { _, _ in },
      )
      try await registry.recover()
      let server = try await ServeNIOServer.bind(unixDomainSocketPath: socket, handler: registry.handler)
      guard chmod(socket, 0o600) == 0 else { await server.shutdown(); throw OperationError(.invalidConfiguration) }
      await withTaskGroup(of: Void.self) { group in
        group.addTask { await registry.run() }
        await server.runUntilCancelled()
        group.cancelAll()
      }
      try await http.shutdown()
    } catch { try await http.shutdown(); throw error }
  }

  public static func run(directory: String) async throws {
    let manifest = try await SupervisorFiles.live.load(directory)
    try validateManifest(manifest, directory: directory)
    _ = signal(SIGPIPE, SIG_IGN)
    let clock = OperationClock.continuous
    let limits = OperationLimits()
    let agent = try OperationAgent(machine: manifest.machine, kinds: [AnyOperationKind(ExecKind(clock: clock))], clock: clock, limits: limits, authorize: { request, _ in
      guard request.headers["X-Wuhu-Supervisor-Nonce"] == manifest.nonce else { throw OperationError(.machineNotAuthorized) }
    })
    defer {
      _ = unlink(manifest.socket)
      _ = unlink(directory + "/manifest.json")
      _ = rmdir(directory)
    }
    let gate = SupervisorGate(manifest: manifest, agent: agent)
    let server = try await ServeNIOServer.bind(unixDomainSocketPath: manifest.socket, handler: gate.handler)
    guard chmod(manifest.socket, 0o600) == 0 else { await server.shutdown(); throw OperationError(.invalidConfiguration) }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }
      group.addTask {
        while !Task.isCancelled {
          do { try await clock.sleep(.seconds(1)) } catch { return }
          let hasOperations = await agent.hasRetainedOperations()
          if await gate.expired(now: clock.now(), lease: .milliseconds(limits.leaseMs), hasOperations: hasOperations) { return }
        }
      }
      _ = await group.next()
      await agent.shutdown(); await server.shutdown(); group.cancelAll()
    }
  }
}

actor SupervisorGate {
  let manifest: SupervisorManifest
  let agent: OperationAgent
  var started = false
  init(manifest: SupervisorManifest, agent: OperationAgent) { self.manifest = manifest; self.agent = agent }
  nonisolated var handler: Handler { { try await self.handle($0) } }
  func expired(now: Duration, lease: Duration, hasOperations: Bool) -> Bool {
    started ? !hasOperations : now >= lease
  }

  func handle(_ request: Request) async throws -> Response {
    guard request.headers["X-Wuhu-Supervisor-Nonce"] == manifest.nonce else { return try .json(ErrorEnvelope(.init(.machineNotAuthorized)), status: .forbidden) }
    if request.url.path == "/identity", request.method == .get {
      var response = try Response.json(manifest)
      if let snapshot = await agent.inspect(manifest.operation) {
        response.headers[.init("X-Wuhu-Supervisor-Active")!] = snapshot.verdict == nil ? "1" : "0"
        response.headers[.init("X-Wuhu-Supervisor-Reservation")!] = String(snapshot.bufferReservationBytes! + (snapshot.finalOffsets.count == 2 ? 0 : ExecSupervisorRegistry.stagingReservation))
      }
      return response
    }
    let path = request.url.path.split(separator: "/").map(String.init)
    guard path.count >= 6, Array(path.prefix(5)) == ["machine", "v2", "machines", manifest.machine, "operations"],
          UUID(uuidString: path[5]) == manifest.operation else { return try .json(ErrorEnvelope(.init(.unknownOperation)), status: .notFound) }
    if request.method == .post {
      guard !started else { return try .json(ErrorEnvelope(.init(.operationExists)), status: .conflict) }
      started = true
    }
    return try await agent.handler(request)
  }
}
