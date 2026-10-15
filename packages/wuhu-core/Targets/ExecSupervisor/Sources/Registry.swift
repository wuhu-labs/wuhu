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
  var tombstones: [UUID: OperationError] = [:]
  var malformedDirectories: Set<String> = []
  var childPIDs: Set<Int32> = []

  init(
    machine: String,
    operationsDirectory: String,
    executable: String,
    fetch: FetchClient,
    identityFetch: FetchClient? = nil,
    authorize: @escaping @Sendable (Request, String) async throws -> Void,
  ) throws {
    try self.init(machine: machine, operationsDirectory: operationsDirectory, executable: executable, fetch: fetch, authorize: authorize, files: .live, clock: .continuous, identityFetch: identityFetch, launch: { executable, directory in
      var pid: Int32 = 0
      let code = exec_launch_supervisor(executable, directory, &pid)
      guard code == 0 else { throw OperationError(.spawnFailed, details: ["errno": .number(Double(code))]) }
      return pid
    })
  }

  init(machine: String, operationsDirectory: String, executable: String, fetch: FetchClient, authorize: @escaping @Sendable (Request, String) async throws -> Void, files: SupervisorFiles, clock: OperationClock, identityFetch: FetchClient? = nil, launch: @escaping @Sendable (String, String) async throws -> Int32?) throws {
    guard !machine.isEmpty, !machine.contains("/"), operationsDirectory.hasPrefix("/"), executable.hasPrefix("/") else { throw OperationError(.invalidConfiguration) }
    self.machine = machine; root = operationsDirectory; self.executable = executable; self.fetch = fetch; self.authorize = authorize
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
      let response = try await identityFetch(localRequest(request, manifest: manifest))
      if response.status.code == 404 {
        let error = try await response.body.json(ErrorEnvelope.self, upTo: 8192).error
        guard error.code == .unknownOperation else { throw OperationError(.invalidResponse) }
        try await leaveLegacy(manifest)
      } else {
        guard response.status.code == 200, try await departureLiteral(response.body) else { throw OperationError(.supervisorUnavailable, operation: manifest.operation) }
      }
    }
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
        let response = try await identityFetch(localRequest(request, manifest: manifest))
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
    }
  }

  func identify(_ manifest: SupervisorManifest) async throws {
    let request = try localRequest(Request(url: URL(string: "http://supervisor/identity")!), manifest: manifest)
    let response = try await identityFetch(request)
    guard response.status.code == 200,
          try await response.body.json(SupervisorManifest.self, upTo: 4096) == manifest else { throw OperationError(.supervisorIdentityMismatch, message: "identity status \(response.status.code)") }
    if response.headers[.init("X-Wuhu-Supervisor-Active")!] == "0" { active.remove(manifest.operation) }
    if let raw = response.headers[.init("X-Wuhu-Supervisor-Reservation")!], let bytes = Int(raw), (0 ... Self.fullReservation).contains(bytes) { reservations[manifest.operation] = bytes }
  }

  func localRequest(_ request: Request, manifest: SupervisorManifest) throws -> Request {
    guard let encoded = manifest.socket.addingPercentEncoding(withAllowedCharacters: .alphanumerics),
          let url = URL(string: "http+unix://" + encoded + request.url.path + (request.url.query.map { "?" + $0 } ?? "")) else { throw OperationError(.invalidConfiguration) }
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
    let response = try await fetch(localRequest(request, manifest: manifest))
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
      guard manifests[id] == nil && tombstones[id] == nil else { throw OperationError(.operationExists) }
      guard start.kind == "exec.v1" else { throw OperationError(.unknownKind) }
      let input = try JSONDecoder().decode(ExecInput.self, from: Data(start.input.jsonString().utf8)); try input.validate()
      guard manifests.count + tombstones.count + malformedDirectories.count < OperationLimits().receipts, active.count < OperationLimits().activeOperations,
            reservations.values.reduce(0, +) + Self.fullReservation <= OperationLimits().bufferBytes else { throw OperationError(.capacityExceeded) }
      let directory = root + "/" + id.uuidString
      let manifest = SupervisorManifest(version: 1, machine: machine, operation: id, nonce: UUID().uuidString + UUID().uuidString, socket: directory + "/control.sock")
      try validateManifest(manifest, directory: directory)
      manifests[id] = manifest
      active.insert(id); reservations[id] = Self.fullReservation
      creating.insert(id)
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
      var forwarded = request; forwarded.body = try .json(start)
      return try await forward(forwarded, manifest: manifest)
    }
    if let error = tombstones[id] { throw error }
    guard let manifest = manifests[id] else { throw OperationError(.unknownOperation) }
    if recoveryFailures.contains(id) { try await identify(manifest); recoveryFailures.remove(id) }
    return try await forward(request, manifest: manifest)
  }
}

private func departureLiteral(_ body: Body) async throws -> Bool {
  do { return try await body.json(Bool.self, upTo: 32) }
  catch { throw OperationError(.invalidResponse, message: "Malformed supervisor departure receipt") }
}
