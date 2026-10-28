#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Fetch
import enum JSONValue.JSONValue
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

/// One start this machine admitted, for its local audit. `caller` is the server's attribution (`StartRequest.caller`): display only, absent when no session made the call.
public struct AdmittedStart: Sendable {
  public let operation: UUID
  public let kind: String
  public let input: JSONValue
  public let caller: StartRequest.Caller?
}

/// What an external backend holds against the shared budget: each operation it routes, by id, with its buffer reservation, and
/// the receipts and bytes it holds for operations it cannot name yet.
public struct ExternalUsage: Sendable, Equatable {
  public var operations: [UUID: Int]
  public var receipts: Int
  public var bufferBytes: Int
  public init(operations: [UUID: Int] = [:], receipts: Int = 0, bufferBytes: Int = 0) {
    self.operations = operations; self.receipts = receipts; self.bufferBytes = bufferBytes
  }
}

/// A kind whose operations live outside this process (exec workers). The agent charges `reservation` per start against the shared admission budget, routes every request for an id the backend `owns`, or that no in-process kind holds, to `handler`. `ComputerAgent.init` validates the descriptor like an in-process kind and requires `0 ... bufferBytes` for the reservation; `usage()` must report nonnegative counts, or the start or describe fails `supervisorUnavailable`.
public struct ExternalKind: Sendable {
  let descriptor: KindDescriptor
  let reservation: Int
  let handler: Handler
  let usage: @Sendable () async throws -> ExternalUsage
  let owns: @Sendable (UUID) async -> Bool
  public init(
    descriptor: KindDescriptor,
    reservation: Int,
    handler: @escaping Handler,
    usage: @escaping @Sendable () async throws -> ExternalUsage,
    owns: @escaping @Sendable (UUID) async -> Bool,
  ) {
    self.descriptor = descriptor; self.reservation = reservation; self.handler = handler; self.usage = usage
    self.owns = owns
  }
}

/// One machine over file kinds on `files`, extra in-process `kinds` and an optional external kind, behind one authorization gate and one admission budget.
public actor ComputerAgent {
  let machine: String
  let runtime: OperationAgent
  let external: ExternalKind?
  let kinds: [KindDescriptor]
  let clock: OperationClock
  let instance = UUID()
  /// Starts admitted and not yet answered, by id, with their reservations. A start enters only after its admission check, in the
  /// same actor turn, so every later check sees it and no start is charged for one that may still be refused.
  var pending: [UUID: Int] = [:]
  /// Ids whose start is being checked, so a duplicate POST cannot run alongside its first.
  var admitting: Set<UUID> = []
  /// Counts answered admitted starts; a usage probe that overlapped a change here may have missed a start that just left
  /// `pending`, so it is taken again.
  var startsReturned = 0
  var closed = false
  let audit: (@Sendable (AdmittedStart) -> Void)?
  let abandonedEffects: @Sendable () -> Int

  /// `audit` sees every admitted start, in-process or external, once, after the machine answered 201.
  public init(machine: String, files: ComputerFileSystem = .local, kinds: [AnyOperationKind] = [], external: ExternalKind? = nil, audit: (@Sendable (AdmittedStart) -> Void)? = nil) throws {
    try self.init(machine: machine, files: files, kinds: kinds, external: external, clock: .continuous, audit: audit)
  }

  init(machine: String, files: ComputerFileSystem = .local, kinds: [AnyOperationKind] = [], external: ExternalKind? = nil, clock: OperationClock, audit: (@Sendable (AdmittedStart) -> Void)? = nil) throws {
    let local = fileOperationKinds(files: files) + kinds
    try OperationAgent.validate(descriptors: (external.map { [$0.descriptor] } ?? []) + local.map(\.descriptor))
    if let external, !(0 ... OperationLimits().bufferBytes).contains(external.reservation) { throw OperationError(.invalidInput, message: "Invalid machine registry or limits") }
    runtime = try OperationAgent(machine: machine, kinds: local, clock: clock, authorize: { _, id in
      guard id == machine else { throw OperationError(.machineNotAuthorized) }
    })
    self.machine = machine; self.external = external; self.clock = clock; self.audit = audit; abandonedEffects = files.abandonedEffects
    self.kinds = (external.map { [$0.descriptor] } ?? []) + local.map(\.descriptor)
  }

  public nonisolated var handler: Handler { { await self.handle($0) } }
  public func run() async { await runtime.run() }
  public func shutdown() async { closed = true; await runtime.shutdown() }

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
  func externalUsage() async throws -> ExternalUsage {
    guard let external else { return .init() }
    let usage = try await external.usage()
    guard usage.receipts >= 0, usage.bufferBytes >= 0, usage.operations.values.allSatisfy({ $0 >= 0 }) else { throw OperationError(.supervisorUnavailable, message: "Invalid external usage") }
    return usage
  }

  /// Both backends' usage from probes no admitted start answered during, so a start that left `pending` meanwhile is in them.
  func admissionUsage() async throws -> (ExternalUsage, (receipts: Int, bufferBytes: Int)) {
    for _ in 0 ..< 16 {
      let returned = startsReturned
      let a = try await externalUsage(); let b = await runtime.admissionUsage()
      if startsReturned == returned { return (a, b) }
    }
    throw OperationError(.supervisorUnavailable, message: "admissionBusy")
  }

  /// Checked sum; an overflow can only mean the budget `cap` is exhausted.
  static func total(_ values: [Int], cap: String, limit: Int) throws -> Int {
    try values.reduce(0) { sum, value in
      let (result, overflow) = sum.addingReportingOverflow(value)
      guard !overflow else { throw OperationError.capacityExceeded(cap, used: .max, limit: limit) }
      return result
    }
  }

  func route(_ request: Request) async throws -> Response {
    let path = request.url.path.split(separator: "/").map(String.init)
    guard path.count >= 4, Array(path.prefix(3)) == ["machine", "v2", "machines"], path[3] == machine else { throw OperationError(.machineNotAuthorized) }
    if path.count == 4, request.method == .get {
      _ = try await externalUsage()
      return try .json(MachineDescription(instance: instance, acceptingStarts: !closed, limits: .init(), kinds: kinds))
    }
    guard path.count >= 6, path[4] == "operations", let id = UUID(uuidString: path[5]) else { throw OperationError(.unknownOperation) }
    if request.method == .post, path.count == 6 {
      guard !closed else { throw OperationError(.leaving) }
      guard pending[id] == nil, await runtime.inspect(id) == nil, !(await owned(id)) else { throw OperationError(.operationExists) }
      let start = try await request.json(StartRequest.self, upTo: OperationLimits().inputBytes)
      guard let kind = kinds.first(where: { $0.name == start.kind }) else { throw OperationError(.unknownKind) }
      let target = kind.name == external?.descriptor.name ? external : nil
      let reserve = target?.reservation ?? (kind.inputChannels + kind.outputChannels).reduce(0) { $0 + $1.windowBytes }
      guard !closed else { throw OperationError(.leaving) }
      guard pending[id] == nil, !admitting.contains(id) else { throw OperationError(.operationExists) }
      admitting.insert(id)
      defer { admitting.remove(id) }
      guard await runtime.inspect(id) == nil, !(await owned(id)) else { throw OperationError(.operationExists) }
      let (a, b) = try await admissionUsage()
      guard !closed else { throw OperationError(.leaving) }
      // Checked against the starts already admitted plus this one. An external start the backend already routes is in both
      // maps; it counts once, at the larger reservation.
      let ids = Set(a.operations.keys).union(pending.keys).union([id])
      let limits = OperationLimits()
      let receipts = try Self.total([a.receipts, b.receipts, ids.count, abandonedEffects()], cap: "receipts", limit: limits.receipts)
      guard receipts <= limits.receipts else { throw OperationError.capacityExceeded("receipts", used: receipts - 1, limit: limits.receipts) }
      let charges = ids.map { max(a.operations[$0] ?? 0, pending[$0] ?? ($0 == id ? reserve : 0)) }
      let buffered = try Self.total([a.bufferBytes, b.bufferBytes] + charges, cap: "bufferBytes", limit: limits.bufferBytes)
      guard buffered <= limits.bufferBytes else { throw OperationError.capacityExceeded("bufferBytes", used: buffered - reserve, limit: limits.bufferBytes, requested: reserve) }
      pending[id] = reserve
      defer { pending.removeValue(forKey: id); startsReturned &+= 1 }
      var forwarded = request; forwarded.body = try .json(start)
      let response = try await (target?.handler ?? runtime.handler)(forwarded)
      if response.status.code == 201 { audit?(.init(operation: id, kind: start.kind, input: start.input, caller: start.caller)) }
      return response
    }
    if let external {
      // An id no in-process kind holds may be one the backend took before this agent started; it decides.
      if await external.owns(id) { return try await external.handler(request) }
      if await runtime.inspect(id) == nil { return try await external.handler(request) }
    }
    return try await runtime.handler(request)
  }
}
