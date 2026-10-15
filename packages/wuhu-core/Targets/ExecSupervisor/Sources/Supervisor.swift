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
import Fetch
import FetchAsyncHTTPClient
import class NIOPosix.MultiThreadedEventLoopGroup
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
    try await composeComputerAgent(machine: machine, operationsDirectory: operationsDirectory, executable: executable, files: .local, kinds: []) { agent, _ in
      var state = stat()
      if lstat(socket, &state) == 0 {
        guard state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFSOCK else { throw OperationError(.invalidConfiguration) }
        guard unlink(socket) == 0 else { throw OperationError(.invalidConfiguration) }
      }
      let server = try await ServeNIOServer.bind(unixDomainSocketPath: socket, handler: { request in
        if request.url.path == "/leave" { return try await agent.controlHandler(request) }
        return try await agent.handler(request)
      })
      guard chmod(socket, 0o600) == 0 else { await server.shutdown(); throw OperationError(.invalidConfiguration) }
      await server.runUntilCancelled()
    }
  }

  public static func run(directory: String) async throws {
    let manifest = try await SupervisorFiles.live.load(directory)
    try validateManifest(manifest, directory: directory)
    _ = signal(SIGPIPE, SIG_IGN)
    let clock = OperationClock.continuous
    let limits = OperationLimits()
    let agent = try OperationAgent(machine: manifest.machine, kinds: [AnyOperationKind(ExecKind(clock: clock, disclaimResponsibility: manifest.disclaimResponsibility == true))], clock: clock, limits: limits, authorize: { request, _ in
      guard request.headers["X-Wuhu-Supervisor-Nonce"] == manifest.nonce else { throw OperationError(.machineNotAuthorized) }
    })
    defer {
      if manifest.version == 1 { _ = unlink(manifest.socket) }
      _ = unlink(directory + "/manifest.json")
      _ = rmdir(directory)
    }
    let (retirements, retired) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let gate = SupervisorGate(manifest: manifest, agent: agent, retired: { retired.yield() })
    // Version 2 dials the machine's rendezvous socket and creates no socket of its own. Version 1 manifests come only from an older
    // agent that launched this executable; they keep their own listening socket so that agent can still reach them.
    let server = manifest.version == 1 ? try await ServeNIOServer.bind(unixDomainSocketPath: manifest.socket, handler: gate.handler) : nil
    if let server, chmod(manifest.socket, 0o600) != 0 { await server.shutdown(); throw OperationError(.invalidConfiguration) }
    let hello = Rendezvous.Hello(protocol: Rendezvous.protocolName, machine: manifest.machine, operation: manifest.operation, nonce: manifest.nonce)
    let events = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await agent.run() }
      // The redial loop returns only once cancelled.
      if server == nil { group.addTask { await Rendezvous.redial(path: manifest.socket, hello: hello, group: events, handler: gate.handler) } }
      // Retired: the exec is stopping (SIGTERM, then SIGKILL after five seconds). The supervisor exits once it has ended, or at the bound.
      group.addTask {
        for await _ in retirements { break }
        guard !Task.isCancelled else { return }
        let bound = clock.now() + retireBound
        while await agent.hasRunningOperations(), clock.now() < bound {
          do { try await clock.sleep(.milliseconds(20)) } catch { return }
        }
      }
      group.addTask {
        while !Task.isCancelled {
          do { try await clock.sleep(.seconds(1)) } catch { return }
          let hasOperations = await agent.hasRetainedOperations()
          if await gate.expired(now: clock.now(), lease: .milliseconds(limits.leaseMs), hasOperations: hasOperations) { return }
        }
      }
      _ = await group.next()
      await agent.shutdown(); await server?.shutdown(); group.cancelAll()
    }
    try? await events.shutdownGracefully()
  }

  /// How long a retired supervisor waits for its exec to end before it exits anyway: the stop's five-second escalation plus margin.
  static let retireBound: Duration = .seconds(8)
}

actor SupervisorGate {
  let manifest: SupervisorManifest
  let agent: OperationAgent
  let retired: @Sendable () -> Void
  var started = false
  var retiring = false
  init(manifest: SupervisorManifest, agent: OperationAgent, retired: @escaping @Sendable () -> Void = {}) { self.manifest = manifest; self.agent = agent; self.retired = retired }
  nonisolated var handler: Handler { { try await self.handle($0) } }
  func expired(now: Duration, lease: Duration, hasOperations: Bool) -> Bool {
    started ? !hasOperations : now >= lease
  }

  func handle(_ request: Request) async throws -> Response {
    guard request.headers["X-Wuhu-Supervisor-Nonce"] == manifest.nonce else { return try .json(ErrorEnvelope(.init(.machineNotAuthorized)), status: .forbidden) }
    if request.url.path == "/leave", request.method == .put {
      await agent.leave()
      return try .json(true)
    }
    // The agent stops serving this machine: stop the exec, refuse a start, and exit, dropping the receipts. The reply may not
    // outlive an idle supervisor; the agent takes the operation directory's removal as the answer.
    if request.url.path == "/retire", request.method == .put {
      retiring = true
      await agent.stopRunning(reason: "retired")
      retired()
      return try .json(true)
    }
    if request.url.path == "/departure", request.method == .get {
      return try .json(await agent.departureSettled())
    }
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
      guard !retiring else { return try .json(ErrorEnvelope(.init(.leaving)), status: .init(code: OperationError(.leaving).statusCode)) }
      guard !started else { return try .json(ErrorEnvelope(.init(.operationExists)), status: .conflict) }
      started = true
    }
    return try await agent.handler(request)
  }
}
