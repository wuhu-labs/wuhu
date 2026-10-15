#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.KindDescriptor
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import struct OperationProtocol.StartRequest
import struct OperationRuntime.AnyOperationKind
import class OperationRuntime.OperationAgent
import typealias Serve.Handler

public enum ExternalDeparture: Sendable {
  case pending, drained, leaseExpired([UUID])
}

/// A kind whose operations live outside this process (exec supervisors). The agent charges `reservation` per start against the shared admission budget, routes every request for an id the backend `owns` to `handler`, and drains it on leave. `ComputerAgent.init` validates the descriptor like an in-process kind and requires `0 ... bufferBytes` for the reservation; `usage()` must report nonnegative counts, or the start or describe fails `supervisorUnavailable`.
public struct ExternalKind: Sendable {
  let descriptor: KindDescriptor
  let reservation: Int
  let handler: Handler
  let usage: @Sendable () async throws -> (active: Int, receipts: Int, bufferBytes: Int)
  let owns: @Sendable (UUID) async -> Bool
  let leave: @Sendable () async throws -> Void
  let departure: @Sendable () async throws -> ExternalDeparture
  public init(
    descriptor: KindDescriptor,
    reservation: Int,
    handler: @escaping Handler,
    usage: @escaping @Sendable () async throws -> (active: Int, receipts: Int, bufferBytes: Int),
    owns: @escaping @Sendable (UUID) async -> Bool,
    leave: @escaping @Sendable () async throws -> Void,
    departure: @escaping @Sendable () async throws -> ExternalDeparture,
  ) {
    self.descriptor = descriptor; self.reservation = reservation; self.handler = handler; self.usage = usage
    self.owns = owns; self.leave = leave; self.departure = departure
  }
}

/// One machine over file kinds on `files`, extra in-process `kinds` and an optional external kind, behind one authorization gate and one admission budget. `leave()` completes only after the server's `?leaveAck=true` describe, bounded by one lease.
public actor ComputerAgent {
  let machine: String
  let runtime: OperationAgent
  let external: ExternalKind?
  let kinds: [KindDescriptor]
  let clock: OperationClock
  let instance = UUID()
  var pending: [UUID: Int] = [:]
  var admissionGeneration: UInt64 = 0
  var leaving = false
  public private(set) var leaveAcknowledged = false
  var drainCompleted = false
  var departureLoss: OperationError?
  var leaveExpired = false
  var leaveDeadline: Duration?

  public init(machine: String, files: ComputerFileSystem = .local, kinds: [AnyOperationKind] = [], external: ExternalKind? = nil) throws {
    try self.init(machine: machine, files: files, kinds: kinds, external: external, clock: .continuous)
  }

  init(machine: String, files: ComputerFileSystem = .local, kinds: [AnyOperationKind] = [], external: ExternalKind? = nil, clock: OperationClock) throws {
    let local = fileOperationKinds(files: files) + kinds
    try OperationAgent.validate(descriptors: (external.map { [$0.descriptor] } ?? []) + local.map(\.descriptor))
    if let external, !(0 ... OperationLimits().bufferBytes).contains(external.reservation) { throw OperationError(.invalidInput, message: "Invalid machine registry or limits") }
    runtime = try OperationAgent(machine: machine, kinds: local, clock: clock, authorize: { _, id in
      guard id == machine else { throw OperationError(.machineNotAuthorized) }
    })
    self.machine = machine; self.external = external; self.clock = clock
    self.kinds = (external.map { [$0.descriptor] } ?? []) + local.map(\.descriptor)
  }

  public nonisolated var handler: Handler { { await self.handle($0) } }
  public func run() async { await runtime.run() }
  public func shutdown() async { await runtime.shutdown() }

  public func leave() async throws {
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
  }

  func expireLeave() -> OperationError {
    leaveExpired = true
    return departureLoss ?? OperationError(.requestDeadline, message: drainCompleted ? "leaveUnacknowledged" : "drainFailed")
  }

  func drain() async throws {
    await runtime.leave()
    while !pending.isEmpty { try await clock.sleep(.milliseconds(10)); try Task.checkCancellation() }
    try await external?.leave()
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
    let evidence = try await external?.departure() ?? .drained
    guard await runtime.departureSettled() else { return false }
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

  func owned(_ id: UUID) async -> Bool { await external?.owns(id) ?? false }

  /// The external backend's usage, refused when any count is negative so it can never lend budget to the shared caps.
  func externalUsage() async throws -> (active: Int, receipts: Int, bufferBytes: Int) {
    guard let external else { return (0, 0, 0) }
    let usage = try await external.usage()
    guard usage.active >= 0, usage.receipts >= 0, usage.bufferBytes >= 0 else { throw OperationError(.supervisorUnavailable, message: "Invalid external usage") }
    return usage
  }

  /// Checked sum; an overflow can only mean the budget is exhausted.
  static func total(_ values: [Int]) throws -> Int {
    try values.reduce(0) { sum, value in
      let (result, overflow) = sum.addingReportingOverflow(value)
      guard !overflow else { throw OperationError(.capacityExceeded) }
      return result
    }
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
      _ = try await externalUsage()
      return try .json(MachineDescription(instance: instance, acceptingStarts: !leaving, limits: .init(), kinds: kinds))
    }
    guard path.count >= 6, path[4] == "operations", let id = UUID(uuidString: path[5]) else { throw OperationError(.unknownOperation) }
    if request.method == .post, path.count == 6 {
      guard !leaving else { throw OperationError(.leaving) }
      guard pending[id] == nil, await runtime.inspect(id) == nil, !(await owned(id)) else { throw OperationError(.operationExists) }
      let start = try await request.json(StartRequest.self, upTo: OperationLimits().inputBytes)
      guard let kind = kinds.first(where: { $0.name == start.kind }) else { throw OperationError(.unknownKind) }
      let target = kind.name == external?.descriptor.name ? external : nil
      let reserve = target?.reservation ?? (kind.inputChannels + kind.outputChannels).reduce(0) { $0 + $1.windowBytes }
      let generation = admissionGeneration
      let a = try await externalUsage(); let b = await runtime.admissionUsage()
      // Awaited probes can interleave with other admissions; pending covers all not-yet-returned starts.
      guard !leaving else { throw OperationError(.leaving) }
      guard pending[id] == nil, await runtime.inspect(id) == nil, !(await owned(id)) else { throw OperationError(.operationExists) }
      guard generation == admissionGeneration else { throw OperationError(.capacityExceeded) }
      let reserved = try Self.total(Array(pending.values))
      guard try Self.total([a.active, b.active, pending.count]) < OperationLimits().activeOperations,
            try Self.total([a.receipts, b.receipts, pending.count]) < OperationLimits().receipts,
            try Self.total([a.bufferBytes, b.bufferBytes, reserved, reserve]) <= OperationLimits().bufferBytes else { throw OperationError(.capacityExceeded) }
      pending[id] = reserve; admissionGeneration += 1
      defer { pending.removeValue(forKey: id); admissionGeneration += 1 }
      var forwarded = request; forwarded.body = try .json(start)
      return try await (target?.handler ?? runtime.handler)(forwarded)
    }
    if let external, await external.owns(id) { return try await external.handler(request) }
    return try await runtime.handler(request)
  }
}
