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
import func ComputerFiles.fileOperationKinds
import Fetch
import FetchAsyncHTTPClient
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import struct OperationProtocol.StartRequest
import class OperationRuntime.OperationAgent
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
    let lock = exec_lock_agent(operationsDirectory)
    guard lock >= 0 else { throw OperationError(.invalidConfiguration, message: "Another agent owns this v2 home") }
    defer { exec_close(lock) }
    if lstat(controlSocket, &state) == 0 {
      guard state.st_uid == getuid(), state.st_mode & S_IFMT == S_IFSOCK, unlink(controlSocket) == 0 else { throw OperationError(.invalidConfiguration) }
    }
    try await withUnixHTTP { http in
      let registry = try ExecSupervisorRegistry(machine: machine, operationsDirectory: operationsDirectory, executable: executable, fetch: .asyncHTTPClient(http, timeout: .seconds(25)), identityFetch: .asyncHTTPClient(http, timeout: .seconds(2)), authorize: { _, id in
        guard id == machine else { throw OperationError(.machineNotAuthorized) }
      })
      try await registry.recover()
      let files = try OperationAgent(machine: machine, kinds: fileOperationKinds(), authorize: { _, id in
        guard id == machine else { throw OperationError(.machineNotAuthorized) }
      })
      let agent = ComputerAgent(machine: machine, registry: registry, files: files)
      let server = try await ServeNIOServer.bind(unixDomainSocketPath: controlSocket, handler: agent.controlHandler)
      guard chmod(controlSocket, 0o600) == 0 else { await server.shutdown(); throw OperationError(.invalidConfiguration) }
      defer { _ = unlink(controlSocket) }
      do {
        try await withThrowingTaskGroup(of: Void.self) { group in
          group.addTask { await registry.run() }
          group.addTask { await files.run() }
          group.addTask { await server.runUntilCancelled() }
          group.addTask { try await serve(agent.handler, { await agent.leaveAcknowledged }) }
          do { _ = try await group.next() }
          catch { await files.shutdown(); await server.shutdown(); group.cancelAll(); throw error }
          await files.shutdown(); await server.shutdown(); group.cancelAll()
        }
      } catch { await files.shutdown(); await server.shutdown(); throw error }
    }
  }
}

actor ComputerAgent {
  let machine: String
  let registry: ExecSupervisorRegistry
  let files: OperationAgent
  let clock: OperationClock
  let instance = UUID()
  var pending: [UUID: Int] = [:]
  var admissionGeneration: UInt64 = 0
  var leaving = false
  var leaveAcknowledged = false
  var drainCompleted = false
  var departureLoss: OperationError?
  var leaveExpired = false
  var leaveDeadline: Duration?

  init(machine: String, registry: ExecSupervisorRegistry, files: OperationAgent, clock: OperationClock = .continuous) {
    self.machine = machine; self.registry = registry; self.files = files; self.clock = clock
  }

  nonisolated var handler: Handler { { await self.handle($0) } }
  nonisolated var controlHandler: Handler { { await self.control($0) } }

  func control(_ request: Request) async -> Response {
    do {
      guard request.method == .put, request.url.path == "/leave" else { throw OperationError(.invalidInput) }
      if !leaving { leaving = true; leaveDeadline = clock.now() + .milliseconds(OperationLimits().leaseMs) }
      try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await self.drain() }
        let remaining = max(.zero, leaveDeadline! - clock.now())
        group.addTask {
          try await self.clock.sleep(remaining)
          throw await self.expireLeave()
        }
        defer { group.cancelAll() }
        _ = try await group.next()
      }
      return try .json(true)
    } catch {
      let error = error as? OperationError ?? .init(.supervisorUnavailable)
      return try! .json(ErrorEnvelope(error), status: .init(code: error.statusCode))
    }
  }

  func expireLeave() -> OperationError {
    leaveExpired = true
    return departureLoss ?? OperationError(.requestDeadline, message: drainCompleted ? "leaveUnacknowledged" : "drainFailed")
  }

  func drain() async throws {
    await files.leave()
    while !pending.isEmpty { try await clock.sleep(.milliseconds(10)); try Task.checkCancellation() }
    try await registry.leave()
    while !drainCompleted {
      if try await settled() { drainCompleted = true; break }
      try await clock.sleep(.milliseconds(10)); try Task.checkCancellation()
    }
    while !leaveAcknowledged {
      guard !leaveExpired else { throw OperationError(.requestDeadline, message: "leaveUnacknowledged") }
      try await clock.sleep(.milliseconds(10)); try Task.checkCancellation()
    }
  }

  func settled() async throws -> Bool {
    let evidence = try await registry.departureEvidence()
    guard await files.departureSettled() else { return false }
    switch evidence {
    case .pending: return false
    case .drained: return true
    case let .leaseExpired(ids):
      leaveExpired = true
      let error = OperationError(.requestDeadline, message: "leaveUnacknowledged", operation: ids.first, details: ["reason": "legacyLeaseExpired", "operations": .array(ids.map { .string($0.uuidString) })])
      departureLoss = error
      throw error
    }
  }

  func handle(_ request: Request) async -> Response {
    var response: Response
    do { response = try await route(request) }
    catch {
      let error = error as? OperationError ?? .init(.invalidInput)
      response = try! .json(ErrorEnvelope(error), status: .init(code: error.statusCode))
    }
    response.headers[.init("X-Wuhu-Agent-Instance")!] = instance.uuidString
    response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
    response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
    response.headers[.cacheControl] = "no-store"
    return response
  }

  func route(_ request: Request) async throws -> Response {
    let path = request.url.path.split(separator: "/").map(String.init)
    guard path.count >= 4, Array(path.prefix(3)) == ["machine", "v2", "machines"], path[3] == machine else { throw OperationError(.machineNotAuthorized) }
    if path.count == 4, request.method == .get {
      let ack = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "leaveAck" && $0.value == "true" } == true
      let expired = leaveExpired || (leaveDeadline.map { clock.now() >= $0 } ?? false)
      if leaving, !expired, pending.isEmpty, try await settled() {
        drainCompleted = true
        if ack { leaveAcknowledged = true }
        throw OperationError(.leaving)
      }
      guard !ack else { throw OperationError(.invalidInput) }
      guard !expired else { throw departureLoss ?? OperationError(.requestDeadline, message: drainCompleted ? "leaveUnacknowledged" : "drainFailed") }
      _ = try await registry.admissionUsage()
      return try .json(MachineDescription(instance: instance, acceptingStarts: !leaving, limits: .init(), kinds: [ComputerKindSchemas.exec] + fileOperationKinds().map(\.descriptor)))
    }
    guard path.count >= 6, path[4] == "operations", let id = UUID(uuidString: path[5]) else { throw OperationError(.unknownOperation) }
    if request.method == .post, path.count == 6 {
      guard !leaving else { throw OperationError(.leaving) }
      guard pending[id] == nil, await files.inspect(id) == nil, !(await registry.owns(id)) else { throw OperationError(.operationExists) }
      let start = try await request.json(StartRequest.self, upTo: OperationLimits().inputBytes)
      let exec = start.kind == "exec.v1"
      let descriptors = fileOperationKinds().map(\.descriptor)
      guard exec || descriptors.contains(where: { $0.name == start.kind }) else { throw OperationError(.unknownKind) }
      let reserve = exec ? ExecSupervisorRegistry.fullReservation : descriptors.first { $0.name == start.kind }!.outputChannels.reduce(0) { $0 + $1.windowBytes }
      let generation = admissionGeneration
      let a = try await registry.admissionUsage(); let b = await files.admissionUsage()
      // Awaited probes can interleave with other admissions; pending covers all not-yet-returned starts.
      guard !leaving else { throw OperationError(.leaving) }
      guard pending[id] == nil, await files.inspect(id) == nil, !(await registry.owns(id)) else { throw OperationError(.operationExists) }
      guard generation == admissionGeneration else { throw OperationError(.capacityExceeded) }
      guard a.active + b.active + pending.count < OperationLimits().activeOperations,
            a.receipts + b.receipts + pending.count < OperationLimits().receipts,
            a.bufferBytes + b.bufferBytes + pending.values.reduce(0, +) + reserve <= OperationLimits().bufferBytes else { throw OperationError(.capacityExceeded) }
      pending[id] = reserve; admissionGeneration += 1
      defer { pending.removeValue(forKey: id); admissionGeneration += 1 }
      var forwarded = request; forwarded.body = try .json(start)
      return try await (exec ? registry.handler : files.handler)(forwarded)
    }
    if await registry.owns(id) { return try await registry.handler(request) }
    return try await files.handler(request)
  }
}
