#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import class AsyncHTTPClient.HTTPClient
import CExecSupervisor
import enum ComputerFiles.ExternalDeparture
import Fetch
import FetchAsyncHTTPClient
import enum JSONValue.JSONValue
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.StopRequest
import typealias Serve.Handler

actor ExecSupervisorRegistry {
  let machine: String
  let root: String
  let executable: String
  let disclaimResponsibility: Bool
  let clock: OperationClock
  let fetch: FetchClient
  let identityFetch: FetchClient
  let files: SupervisorFiles
  let launch: @Sendable (String, String) async throws -> Int32?
  let authorize: @Sendable (Request, String) async throws -> Void
  let instance = UUID()
  var manifests: [UUID: SupervisorManifest] = [:]
  var leaving = false
  struct LegacyDeparture {
    var leaseUntil: Duration
    var snapshot: OperationSnapshot?
    var lost = false
  }

  typealias DepartureEvidence = ExternalDeparture

  var legacyDepartures: [UUID: LegacyDeparture] = [:]
  var terminalAcknowledgements: [UUID: UUID] = [:]
  static let stagingReservation = 1024 * 1024
  static let fullReservation = 576 * 1024 + stagingReservation
  var reservations: [UUID: Int] = [:]
  var active: Set<UUID> = []
  var recoveryFailures: Set<UUID> = []
  var creating: Set<UUID> = []
  /// Starts admitted past the last `leaving` check whose request has not yet gone to their supervisor. Retirement waits for them,
  /// so each is either refused or has a manifest retirement reaches.
  var starting: Set<UUID> = []
  var tombstones: [UUID: OperationError] = [:]
  var malformedDirectories: Set<String> = []
  var childPIDs: Set<Int32> = []
  /// Live rendezvous links from version-2 supervisors, newest per operation.
  struct Link {
    var client: FetchClient
    var generation: UInt64
    var abort: @Sendable () -> Void
  }

  var links: [UUID: Link] = [:]
  var linkGenerations: UInt64 = 0
  /// Why the agent stopped serving the machine, once it has; a revocation outranks a turn-off.
  var retirement: SupervisorRetirement?
  static let retireDeadline: Duration = .seconds(10)

  init(
    machine: String,
    operationsDirectory: String,
    executable: String,
    fetch: FetchClient,
    identityFetch: FetchClient? = nil,
    disclaimResponsibility: Bool = false,
    authorize: @escaping @Sendable (Request, String) async throws -> Void,
  ) throws {
    try self.init(machine: machine, operationsDirectory: operationsDirectory, executable: executable, fetch: fetch, authorize: authorize, files: .live, clock: .continuous, identityFetch: identityFetch, disclaimResponsibility: disclaimResponsibility, launch: { executable, directory in
      var pid: Int32 = 0
      let code = exec_launch_supervisor(executable, directory, &pid)
      guard code == 0 else { throw OperationError(.spawnFailed, details: ["errno": .number(Double(code))]) }
      return pid
    })
  }

  init(machine: String, operationsDirectory: String, executable: String, fetch: FetchClient, authorize: @escaping @Sendable (Request, String) async throws -> Void, files: SupervisorFiles, clock: OperationClock, identityFetch: FetchClient? = nil, disclaimResponsibility: Bool = false, launch: @escaping @Sendable (String, String) async throws -> Int32?) throws {
    guard !machine.isEmpty, !machine.contains("/"), operationsDirectory.hasPrefix("/"), executable.hasPrefix("/") else { throw OperationError(.invalidConfiguration) }
    self.machine = machine; root = operationsDirectory; self.executable = executable; self.fetch = fetch; self.authorize = authorize
    self.disclaimResponsibility = disclaimResponsibility
    self.files = files; self.clock = clock; self.launch = launch; self.identityFetch = identityFetch ?? fetch
  }

  func admissionUsage() async throws -> (active: Int, receipts: Int, bufferBytes: Int) {
    try await refreshReceipts()
    return (active.count, manifests.count + tombstones.count + malformedDirectories.count, reservations.values.reduce(0, +))
  }

  func owns(_ id: UUID) -> Bool { manifests[id] != nil || tombstones[id] != nil }

  func leave() async throws {
    leaving = true
    try await refreshReceipts()
    guard creating.isEmpty, tombstones.isEmpty, malformedDirectories.isEmpty else { throw OperationError(.supervisorUnavailable) }
    for manifest in manifests.values {
      if legacyDepartures[manifest.operation] != nil { continue }
      let request = Request(url: URL(string: "http://supervisor/leave")!, method: .put)
      let response = try await send(request, to: manifest, identity: true)
      if response.status.code == 404 {
        let error = try await response.body.json(ErrorEnvelope.self, upTo: 8192).error
        guard error.code == .unknownOperation else { throw OperationError(.invalidResponse) }
        try await leaveLegacy(manifest)
      } else {
        guard response.status.code == 200, try await departureLiteral(response.body) else { throw OperationError(.supervisorUnavailable, operation: manifest.operation) }
      }
    }
  }

  /// Asks every supervisor of this machine to stop its exec, drop its receipts and exit, then waits at most `deadline` for their
  /// operation directories to go. A supervisor that refuses (a published one without the verb) or does not answer in time is left to
  /// its own lease and receipt expiry; no process is signalled. Returns the operations still present.
  @discardableResult
  func retire(_ reason: SupervisorRetirement, deadline: Duration = retireDeadline) async -> Set<UUID> {
    if retirement != .revoked { retirement = reason }
    leaving = true
    let until = clock.now() + deadline
    // A start in flight finishes creating and launching its supervisor, then sees `leaving` and is refused before its exec runs.
    while !starting.isEmpty, clock.now() < until {
      do { try await clock.sleep(.milliseconds(10)) } catch { break }
    }
    let targets = Array(manifests.values)
    let asked = await withTaskGroup(of: UUID?.self, returning: Set<UUID>.self) { group in
      for manifest in targets { group.addTask { await self.askToRetire(manifest) ? manifest.operation : nil } }
      var asked = Set<UUID>()
      for await id in group { if let id { asked.insert(id) } }
      return asked
    }
    var waiting = asked
    while !waiting.isEmpty {
      let retained = Set((try? await files.list(root)) ?? [])
      waiting = waiting.filter { retained.contains(root + "/" + $0.uuidString) }
      guard !waiting.isEmpty, clock.now() < until else { break }
      do { try await clock.sleep(.milliseconds(25)) } catch { break }
    }
    try? await refreshReceipts()
    return Set(manifests.keys).union(tombstones.keys)
  }

  /// Whether to wait for this supervisor's directory: it accepted, or its answer was lost (an idle supervisor exits at once).
  /// An explicit refusal means it will not exit.
  func askToRetire(_ manifest: SupervisorManifest) async -> Bool {
    let response: Response
    do { response = try await send(Request(url: URL(string: "http://supervisor/retire")!, method: .put), to: manifest, identity: true) }
    catch { return true }
    guard response.status.code == 200 else { try? await response.body.discard(); return false }
    return (try? await departureLiteral(response.body)) ?? true
  }

  func leaveLegacy(_ manifest: SupervisorManifest) async throws {
    legacyDepartures[manifest.operation] = .init(leaseUntil: clock.now() + .milliseconds(OperationLimits().leaseMs))
    let request = Request(url: URL(string: "http://supervisor/machine/v2/machines/" + machine + "/operations/" + manifest.operation.uuidString + "/stop")!, method: .put, body: try .json(StopRequest(reason: "leaving")))
    let response = try await forward(request, manifest: manifest)
    if response.status.code == 404 {
      guard try await response.body.json(ErrorEnvelope.self, upTo: 8192).error.code == .unknownOperation else { throw OperationError(.invalidResponse) }
      legacyDepartures[manifest.operation]?.lost = true
    } else {
      guard response.status.code == 200 else { throw OperationError(.supervisorUnavailable, operation: manifest.operation) }
      try await response.body.discard()
    }
  }

  func legacyEvidence(_ manifest: SupervisorManifest) async throws -> DepartureEvidence {
    guard let state = legacyDepartures[manifest.operation] else { return .pending }
    let retained = retainedLegacyEvidence(state, operation: manifest.operation)
    switch retained {
    case .drained: return .drained
    case .leaseExpired:
      legacyDepartures[manifest.operation]?.lost = true
      return retained
    case .pending: break
    }
    guard clock.now() >= state.leaseUntil else { return .pending }
    // A lease duration permits an observation; it is not evidence of a process exit.
    let request = Request(url: URL(string: "http://supervisor/machine/v2/machines/" + machine + "/operations/" + manifest.operation.uuidString)!)
    let response = try await forward(request, manifest: manifest)
    if response.status.code == 404 {
      guard try await response.body.json(ErrorEnvelope.self, upTo: 8192).error.code == .unknownOperation else { throw OperationError(.invalidResponse) }
      legacyDepartures[manifest.operation]?.lost = true
      return .leaseExpired([manifest.operation])
    }
    guard response.status.code == 200 else { throw OperationError(.supervisorUnavailable, operation: manifest.operation) }
    try await response.body.discard()
    return try await legacyEvidence(manifest)
  }

  func retainedLegacyEvidence(_ state: LegacyDeparture, operation: UUID) -> DepartureEvidence {
    if state.lost || (state.snapshot?.verdict?.tag == .stopped && state.snapshot?.verdict?.reason == "leaseExpired") { return .leaseExpired([operation]) }
    if let snapshot = state.snapshot, snapshot.verdict != nil, snapshot.outputConsumed,
       let token = snapshot.terminalToken, terminalAcknowledgements[operation] == token { return .drained }
    return .pending
  }

  func departureSettled() async throws -> Bool {
    if case .drained = try await departureEvidence() { return true }
    return false
  }

  func departureEvidence() async throws -> DepartureEvidence {
    guard leaving, creating.isEmpty else { return .pending }
    try await refreshReceipts()
    if let error = tombstones.values.first(where: { $0.message == "legacyReceiptDisappeared" }) { throw error }
    guard tombstones.isEmpty, malformedDirectories.isEmpty else { return .pending }
    var pending = false
    var lost: [UUID] = []
    for manifest in manifests.values {
      if legacyDepartures[manifest.operation] == nil {
        let request = Request(url: URL(string: "http://supervisor/departure")!)
        let response = try await send(request, to: manifest, identity: true)
        if response.status.code == 404 {
          guard try await response.body.json(ErrorEnvelope.self, upTo: 8192).error.code == .unknownOperation else { throw OperationError(.invalidResponse) }
          try await leaveLegacy(manifest)
        } else {
          guard response.status.code == 200 else { throw OperationError(.supervisorUnavailable, operation: manifest.operation) }
          if !(try await departureLiteral(response.body)) { pending = true }
          continue
        }
      }
      switch try await legacyEvidence(manifest) {
      case .pending: pending = true
      case .drained: break
      case let .leaseExpired(ids): lost += ids
      }
    }
    if pending { return .pending }
    return lost.isEmpty ? .drained : .leaseExpired(lost)
  }

  func recover() async throws {
    let directories = try await files.list(root)
    guard directories.count <= OperationLimits().receipts else { throw OperationError(.capacityExceeded) }
    for directory in directories {
      guard let id = UUID(uuidString: URL(fileURLWithPath: directory).lastPathComponent), directory == root + "/" + id.uuidString else { malformedDirectories.insert(directory); continue }
      do {
        let manifest = try await files.load(directory)
        try validateManifest(manifest, directory: directory)
        guard manifest.machine == machine else { throw OperationError(.supervisorIdentityMismatch) }
        manifests[id] = manifest
        reservations[id] = Self.fullReservation; active.insert(id); recoveryFailures.insert(id)
      } catch {
        let failure = error as? OperationError ?? .init(.invalidConfiguration)
        tombstones[id] = OperationError(failure.code, message: failure.message, operation: id, details: ["path": .string(directory + "/manifest.json")])
      }
    }
  }

  func run() async {
    while !Task.isCancelled {
      for pid in childPIDs {
        if exec_reap_nonblocking(pid) != 0 { childPIDs.remove(pid) }
      }
      do { try await clock.sleep(.milliseconds(100)) } catch { return }
    }
  }

  nonisolated var handler: Handler { { await self.handle($0) } }

  func refreshReceipts() async throws {
    let candidates = Set(manifests.keys).union(tombstones.keys).filter { !creating.contains($0) }
    let retained = Set(try await files.list(root))
    for id in candidates where !retained.contains(root + "/" + id.uuidString) {
      if let legacy = legacyDepartures[id] {
        switch retainedLegacyEvidence(legacy, operation: id) {
        case .leaseExpired: continue
        case .pending:
          tombstones[id] = OperationError(.supervisorUnavailable, message: "legacyReceiptDisappeared", operation: id, details: ["reason": "localReceiptDisappearance", "unacknowledged": true, "cleanupAuthorized": false])
          continue
        case .drained: break
        }
      }
      terminalAcknowledgements.removeValue(forKey: id)
      tombstones.removeValue(forKey: id); manifests.removeValue(forKey: id); active.remove(id); reservations.removeValue(forKey: id); recoveryFailures.remove(id); legacyDepartures.removeValue(forKey: id)
      links.removeValue(forKey: id)?.abort()
    }
  }

  /// Admits a supervisor that dialed the rendezvous socket: a known version-2 operation of this machine whose manifest nonce it knows.
  /// A newer link for the same operation replaces the older one.
  func link(_ hello: Rendezvous.Hello, client: FetchClient, abort: @escaping @Sendable () -> Void) throws(Rendezvous.Refusal) -> UInt64 {
    guard hello.protocol == Rendezvous.protocolName else { throw .unsupportedProtocol }
    guard let manifest = manifests[hello.operation] else { throw .unknownOperation }
    guard manifest.version == 2 else { throw .manifestVersion }
    guard hello.machine == manifest.machine, manifest.machine == machine else { throw .machineMismatch }
    guard Rendezvous.noncesMatch(hello.nonce, manifest.nonce) else { throw .nonceMismatch }
    linkGenerations += 1
    links[hello.operation]?.abort()
    links[hello.operation] = Link(client: client, generation: linkGenerations, abort: abort)
    return linkGenerations
  }

  func unlink(_ operation: UUID, generation: UInt64) {
    if links[operation]?.generation == generation { links.removeValue(forKey: operation) }
  }

  /// Version 1 supervisors answer on their own socket; version 2 supervisors answer over their rendezvous link, which a supervisor
  /// redials within a second of the agent coming back.
  func send(_ request: Request, to manifest: SupervisorManifest, identity: Bool) async throws -> Response {
    let local = try localRequest(request, manifest: manifest)
    guard manifest.version == 2 else { return try await (identity ? identityFetch : fetch)(local) }
    let clock = ContinuousClock()
    let connected = clock.now + Rendezvous.handshakeTimeout
    while links[manifest.operation] == nil {
      guard clock.now < connected else { throw OperationError(.supervisorUnavailable, message: "supervisorNotConnected", operation: manifest.operation) }
      try await clock.sleep(for: .milliseconds(20))
    }
    let client = links[manifest.operation]!.client
    return try await withDeadline(identity ? .seconds(2) : .seconds(25), operation: manifest.operation) {
      let response = try await client(local)
      let bytes = try await response.body.bytes(upTo: OperationLimits.responseBytes)
      return Response(status: response.status, headers: response.headers, body: .bytes(bytes, contentType: response.body.contentType))
    }
  }

  func identify(_ manifest: SupervisorManifest) async throws {
    let response = try await send(Request(url: URL(string: "http://supervisor/identity")!), to: manifest, identity: true)
    guard response.status.code == 200,
          try await response.body.json(SupervisorManifest.self, upTo: 4096) == manifest else { throw OperationError(.supervisorIdentityMismatch, message: "identity status \(response.status.code)") }
    if response.headers[.init("X-Wuhu-Supervisor-Active")!] == "0" { active.remove(manifest.operation) }
    if let raw = response.headers[.init("X-Wuhu-Supervisor-Reservation")!], let bytes = Int(raw), (0 ... Self.fullReservation).contains(bytes) { reservations[manifest.operation] = bytes }
  }

  func localRequest(_ request: Request, manifest: SupervisorManifest) throws -> Request {
    let query = request.url.query.map { "?" + $0 } ?? ""
    let address = manifest.version == 2 ? "http://localhost" : manifest.socket.addingPercentEncoding(withAllowedCharacters: .alphanumerics).map { "http+unix://" + $0 }
    guard let address, let url = URL(string: address + request.url.path + query) else { throw OperationError(.invalidConfiguration) }
    var copy = request; copy.url = url
    copy.headers["Host"] = "localhost"
    copy.headers["X-Wuhu-Supervisor-Nonce"] = manifest.nonce
    return copy
  }

  func handle(_ request: Request) async -> Response {
    var response: Response
    do { response = try await route(request) }
    catch {
      let failure = error as? OperationError ?? OperationError(.supervisorUnavailable)
      response = try! .json(ErrorEnvelope(failure), status: .init(code: failure.statusCode))
    }
    response.headers[.init("X-Wuhu-Agent-Instance")!] = instance.uuidString
    response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
    response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
    response.headers[.cacheControl] = "no-store"
    return response
  }

  func forward(_ request: Request, manifest: SupervisorManifest) async throws -> Response {
    let response = try await send(request, to: manifest, identity: false)
    let data = try await response.body.bytes(upTo: OperationLimits.responseBytes)
    if (response.status.code == 200 || response.status.code == 201) && !request.url.path.contains("/inputs/") {
      let snapshot = try JSONDecoder().decode(OperationSnapshot.self, from: data)
      guard snapshot.operation == manifest.operation else { throw OperationError(.invalidResponse) }
      let path = request.url.path.split(separator: "/")
      let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      if response.status.code == 200, request.method == .get, path.count == 6, let token = snapshot.terminalToken, snapshot.verdict != nil,
         let accepted = query.first(where: { $0.name == "terminalAck" })?.value,
         UUID(uuidString: accepted) == token { terminalAcknowledgements[manifest.operation] = token }
      if legacyDepartures[manifest.operation] != nil {
        legacyDepartures[manifest.operation]?.snapshot = snapshot
        legacyDepartures[manifest.operation]?.leaseUntil = clock.now() + .milliseconds(OperationLimits().leaseMs)
      }
      if snapshot.verdict != nil { active.remove(manifest.operation) }
      if let bytes = snapshot.bufferReservationBytes {
        guard (0 ... 576 * 1024).contains(bytes) else { throw OperationError(.unsupportedProtocol) }
        let staging = snapshot.finalOffsets.count == 2 ? 0 : Self.stagingReservation
        reservations[manifest.operation] = bytes + staging
      } else if snapshot.outputConsumed && snapshot.verdict != nil {
        reservations[manifest.operation] = 64 * 1024
      }
    }
    return Response(status: response.status, headers: response.headers, body: .bytes(data, contentType: "application/json"))
  }

  func route(_ request: Request) async throws -> Response {
    let path = request.url.path.split(separator: "/").map(String.init)
    guard path.count >= 4, Array(path.prefix(3)) == ["machine", "v2", "machines"], path[3] == machine else { throw OperationError(.unknownMachine) }
    try await authorize(request, machine)
    if path.count == 4, request.method == .get {
      try await refreshReceipts()
      return try .json(MachineDescription(instance: instance, acceptingStarts: !leaving, limits: .init(), kinds: [ComputerKindSchemas.exec]))
    }
    guard path.count >= 6, path[4] == "operations", let id = UUID(uuidString: path[5]) else { throw OperationError(.unknownOperation) }
    if request.method == .post, path.count == 6 {
      try await refreshReceipts()
      guard !leaving else { throw OperationError(.leaving) }
      guard manifests[id] == nil && tombstones[id] == nil else { throw OperationError(.operationExists) }
      let start = try await request.json(StartRequest.self, upTo: OperationLimits().inputBytes)
      // Leaving or retirement may have begun while the body was read.
      guard !leaving else { throw OperationError(.leaving) }
      guard manifests[id] == nil && tombstones[id] == nil else { throw OperationError(.operationExists) }
      guard start.kind == "exec.v1" else { throw OperationError(.unknownKind) }
      let input = try JSONDecoder().decode(ExecInput.self, from: Data(start.input.jsonString().utf8)); try input.validate()
      guard manifests.count + tombstones.count + malformedDirectories.count < OperationLimits().receipts, active.count < OperationLimits().activeOperations,
            reservations.values.reduce(0, +) + Self.fullReservation <= OperationLimits().bufferBytes else { throw OperationError(.capacityExceeded) }
      let directory = root + "/" + id.uuidString
      let manifest = SupervisorManifest(version: 2, machine: machine, operation: id, nonce: UUID().uuidString + UUID().uuidString, socket: Rendezvous.socketPath(operationsDirectory: root), disclaimResponsibility: disclaimResponsibility ? true : nil)
      try validateManifest(manifest, directory: directory)
      manifests[id] = manifest
      active.insert(id); reservations[id] = Self.fullReservation
      creating.insert(id); starting.insert(id)
      defer { starting.remove(id) }
      do { try await files.create(directory, manifest) }
      catch { creating.remove(id); throw error }
      creating.remove(id)
      if let pid = try await launch(executable, directory) { childPIDs.insert(pid) }
      let deadline = clock.now() + .seconds(4)
      while true {
        do { try await identify(manifest); break }
        catch {
          guard clock.now() < deadline else { throw OperationError(.supervisorUnavailable, message: String(describing: error), operation: id) }
          try await clock.sleep(.milliseconds(20))
        }
      }
      // Leaving began while the supervisor launched: it stays idle and never starts the exec. Once retirement has begun, it may
      // have given up on this start at its deadline, so the start retires its own supervisor; after a plain leave, the retirement
      // that follows reaches it.
      guard !leaving else {
        if retirement != nil { _ = await askToRetire(manifest) }
        throw OperationError(.leaving, operation: id)
      }
      starting.remove(id)
      var forwarded = request; forwarded.body = try .json(start)
      return try await forward(forwarded, manifest: manifest)
    }
    if let error = tombstones[id] { throw error }
    guard let manifest = manifests[id] else { throw OperationError(.unknownOperation) }
    if recoveryFailures.contains(id) { try await identify(manifest); recoveryFailures.remove(id) }
    return try await forward(request, manifest: manifest)
  }
}

/// Bounds one rendezvous exchange, the way the legacy HTTP client's timeouts bound a per-operation socket.
private func withDeadline<R: Sendable>(_ duration: Duration, operation: UUID, _ body: @escaping @Sendable () async throws -> R) async throws -> R {
  let work = Task { try await body() }
  let expired = Task { try await ContinuousClock().sleep(for: duration); work.cancel() }
  defer { expired.cancel() }
  do { return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() } }
  catch {
    if work.isCancelled, !Task.isCancelled { throw OperationError(.supervisorUnavailable, message: "supervisorTimeout", operation: operation) }
    throw error
  }
}

private func departureLiteral(_ body: Body) async throws -> Bool {
  do { return try await body.json(Bool.self, upTo: 32) }
  catch { throw OperationError(.invalidResponse, message: "Malformed supervisor departure receipt") }
}
