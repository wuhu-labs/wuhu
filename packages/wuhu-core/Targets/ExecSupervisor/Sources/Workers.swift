import TaskLifetime
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
import enum ComputerFiles.ExternalDeparture
import struct ComputerFiles.ExternalKind
import struct ComputerFiles.ExternalUsage
import Fetch
import enum OperationProtocol.ComputerKindSchemas
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.MachineDescription
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationLimits
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationProtocol.StopRequest
import class OperationRuntime.OperationAgent
import typealias Serve.Handler

/// The agent's side of the machine's exec workers. One worker process, the current one, takes every new exec; it and every
/// earlier worker still holding operations dial `ctl.sock`, and each request goes to the worker holding its operation.
/// Version-2 supervisors an older agent launched, one per operation, are adopted the same way until they exit.
///
/// Workers speak only the hello and the operation protocol. What the agent knows of them is its routes (one per operation, from
/// the starts it forwarded and the inventories of workers it recovered) and the snapshots it forwards; leaving, departure and
/// retirement are its own state, carried out with standard stops.
actor ExecWorkers {
  nonisolated let taskScope = TaskScope()
  nonisolated let transportScope = TaskScope()
  let machine: String
  let operations: String
  let directory: String
  let socket: String
  let executable: String
  let disclaimResponsibility: Bool
  let clock: OperationClock
  /// How long a worker keeps a receipt after its caller's last request: the runtime's, unless a test injects a shorter one,
  /// which reaches the workers through their manifests.
  let retention: Duration
  let launch: @Sendable ([String]) async throws -> Int32?
  let authorize: @Sendable (Request, String) async throws -> Void
  let instance = UUID()

  /// One exec's output is read 8 KiB at a time per channel; the staging stays until both tails are drained.
  static let readStaging = 2 * 8192
  static let windows = (ComputerKindSchemas.exec.inputChannels + ComputerKindSchemas.exec.outputChannels).reduce(0) { $0 + $1.windowBytes }
  /// What an operation is charged until its worker reports the real reservation: the most one can hold.
  static let fullReservation = windows + readStaging
  /// How long a request waits for the worker it needs to (re)dial; workers redial within a second.
  static let linkWait: Duration = .seconds(2)
  /// Bounds one forwarded request; the longest poll holds 20 seconds.
  static let requestDeadline: Duration = .seconds(25)
  static let controlDeadline: Duration = .seconds(2)
  static let retireDeadline: Duration = .seconds(10)
  static let launchBackoffCeiling: Duration = .seconds(5)

  struct Link: Sendable {
    var client: FetchClient
    var generation: UInt64
    var abort: @Sendable () -> Void
  }

  struct Worker {
    var manifest: WorkerManifest
    var pid: Int32?
    var account: Account
    let since: Duration
    var connection = Connection.awaiting

    var link: Link? { if case let .linked(link) = connection { link } else { nil } }
    var everLinked: Bool { if case .awaiting = connection { false } else { true } }
  }

  /// What this agent knows of the operations a worker holds.
  enum Account: Equatable {
    /// Launched by this agent, which forwarded every start it took.
    case launched
    /// Recovered from an earlier agent; its routes come from the inventory read at recovery.
    case inventoried
    /// Recovered with an unreadable inventory: it may hold anything, so admission charges it the most a worker can hold, its
    /// ids are unavailable rather than unknown, and departure waits for it.
    case unreadable
    /// Recovered, and reconciled with the inventory it wrote for its first hello to this agent.
    case reconciled
  }

  enum Connection {
    case awaiting
    case linked(Link)
    /// Was linked; it may redial.
    case dropped
  }

  struct Supervisor {
    var manifest: SupervisorManifest
    var link: Link?
    var retireAsked = false
  }

  enum Owner: Equatable {
    case worker(UUID)
    case supervisor
  }

  struct Route {
    var owner: Owner
    var lastRequest: Duration
    var reservation = ExecWorkers.fullReservation
    var phase = Phase.starting
    /// Output channels whose poll carried the terminal acknowledgement; "" for one that named no channel.
    var acknowledged: Set<String> = []

    enum Phase: Equatable {
      /// Its start is on its way to the worker: an answer that the worker does not know it says nothing yet.
      case starting
      /// No verdict seen; `stopping` while a stop this agent sent for a leave or retirement is on its way.
      case running(stopping: Bool)
      case ended
      /// A verdict, every output consumed and the terminal acknowledged. Never reverts.
      case settled
    }

    var verdict: Bool {
      switch phase {
      case .starting, .running: false
      case .ended, .settled: true
      }
    }

    var settled: Bool { phase == .settled }
  }

  /// Whether the agent serves the machine.
  enum Service: Equatable {
    case serving
    /// No start is routed and every running operation gets the standard stop, reason `leaving`.
    case leaving
    /// As leaving, with stop reason `retired`; every link was cut.
    case retired(SupervisorRetirement)
  }

  var workers: [UUID: Worker] = [:]
  var current: UUID?
  var supervisors: [UUID: Supervisor] = [:]
  var routes: [UUID: Route] = [:]
  /// Operations of version-1 supervisors, which this agent does not adopt: their outcome is unknown.
  var unadopted: Set<UUID> = []
  /// Operations dropped before they settled: the departure reports them. Mirrors `<workers>/lost.json`, written before the
  /// evidence it came from goes, so it outlives any number of agent restarts.
  var lost: Set<UUID> = []
  /// Dead workers whose inventory cannot be read and whose operations no route names: what they dropped is unknown, so the
  /// departure fails rather than report drained, and an id no route names may have been theirs.
  var unaccounted: Set<UUID> = []
  /// A departure was answered drained or lost, so a turn-off after it may clear the ledger.
  var reported = false
  var service = Service.serving
  var launching = false
  var launchBackoff: Duration = .zero
  var nextLaunch: Duration = .zero
  var generations: UInt64 = 0

  init(
    machine: String,
    operationsDirectory: String,
    executable: String,
    disclaimResponsibility: Bool = false,
    clock: OperationClock = .continuous,
    retention: Duration = OperationAgent.receiptRetention,
    launch: @escaping @Sendable ([String]) async throws -> Int32? = { try ExecSupervisor.launchReaped($0) },
    authorize: @escaping @Sendable (Request, String) async throws -> Void,
  ) throws {
    guard !machine.isEmpty, !machine.contains("/"), operationsDirectory.hasPrefix("/"), executable.hasPrefix("/"), retention > .zero else { throw OperationError(.invalidConfiguration) }
    self.machine = machine; operations = operationsDirectory; self.executable = executable; self.disclaimResponsibility = disclaimResponsibility
    directory = Rendezvous.machineDirectory(operationsDirectory: operationsDirectory) + "/workers"
    socket = Rendezvous.socketPath(operationsDirectory: operationsDirectory)
    self.clock = clock; self.retention = retention; self.launch = launch; self.authorize = authorize
  }

  var ledger: String { directory + "/lost.json" }

  /// Adds to the loss ledger, on disk first. False when the write failed; the caller keeps the evidence and tries again.
  @discardableResult
  func recordLost(_ ids: Set<UUID>) -> Bool {
    guard !ids.isSubset(of: lost) else { return true }
    guard (try? WorkerDirectory.writeIDs(ledger, lost.union(ids))) != nil else { return false }
    lost.formUnion(ids)
    return true
  }

  // MARK: Recovery and the run loop

  /// Adopts what an earlier agent left: the loss ledger, live workers (their lock is held) with the operations their
  /// inventories name, the operations dead ones dropped, and version-2 supervisors. A version-1 supervisor is not adopted: its
  /// operation's outcome is unknown, and it is asked to retire.
  func recover() async throws {
    var state = stat()
    if lstat(directory, &state) != 0 { guard mkdir(directory, 0o700) == 0 || errno == EEXIST else { throw OperationError(.invalidConfiguration, details: ["path": .string(directory)]) } }
    guard lstat(directory, &state) == 0, state.st_mode & S_IFMT == S_IFDIR, state.st_uid == getuid(), state.st_mode & 0o077 == 0 else {
      throw OperationError(.invalidConfiguration, message: "\(directory) must be this user's private directory", details: ["path": .string(directory)])
    }
    lost = try WorkerDirectory.ids(ledger)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
      guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
      let path = WorkerDirectory.path(workers: directory, id)
      switch WorkerDirectory.bury(path, keep: { recordLost($0) }) {
      case .alive: break
      case .unaccounted: unaccounted.insert(id); continue
      case .gone, .dead: continue
      }
      guard let manifest = try? WorkerDirectory.load(path), manifest.worker == id, manifest.machine == machine else { continue }
      // Marked first: from here on it admits no start, so the inventory read next names every operation it can hold.
      WorkerDirectory.supersede(path)
      let inventory = try? WorkerDirectory.inventory(path)
      if let inventory { adopt(inventory, from: id) }
      workers[id] = Worker(manifest: manifest, account: inventory == nil ? .unreadable : .inventoried, since: clock.now())
    }
    var retiring: [(UUID, SupervisorManifest, String)] = []
    for name in (try? FileManager.default.contentsOfDirectory(atPath: operations)) ?? [] {
      guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
      let path = operations + "/" + name
      guard let manifest = try? loadSupervisorManifest(path), manifest.operation == id, manifest.machine == machine else { continue }
      if manifest.version == 1 {
        unadopted.insert(id); recordLost([id])
        retiring.append((id, manifest, path))
        continue
      }
      guard (try? validateManifest(manifest, directory: path)) != nil else { continue }
      supervisors[id] = Supervisor(manifest: manifest)
      routes[id] = Route(owner: .supervisor, lastRequest: clock.now())
    }
    await withTaskGroup(of: Void.self) { group in
      for (_, manifest, path) in retiring { group.addTask { Self.retireUnadopted(manifest, directory: path) } }
    }
  }

  /// Routes every operation an inventory names that no route names yet, charged in full until a snapshot says otherwise; a
  /// settled one is charged nothing. What it dropped goes to the ledger.
  func adopt(_ inventory: WorkerInventory, from id: UUID) {
    for operation in inventory.retained where routes[operation] == nil {
      var route = Route(owner: .worker(id), lastRequest: clock.now())
      if !inventory.unsettled.contains(operation) { route.phase = .settled; route.reservation = 0 }
      routes[operation] = route
    }
    for (operation, route) in routes where route.owner == .worker(id) && !route.settled && !inventory.unsettled.contains(operation) && inventory.retained.contains(operation) {
      routes[operation]?.phase = .settled; routes[operation]?.reservation = 0
    }
    recordLost(inventory.lost)
  }

  /// A recovered worker's first hello: the inventory it wrote just before is the truth about it. Operations it no longer holds
  /// lose their routes (the ones it dropped unsettled are in its lost list); the rest are adopted as they now stand.
  func reconcile(_ id: UUID) {
    guard let inventory = try? WorkerDirectory.inventory(WorkerDirectory.path(workers: directory, id)) else { return }
    for (operation, route) in routes where route.owner == .worker(id) && !inventory.retained.contains(operation) { routes.removeValue(forKey: operation) }
    adopt(inventory, from: id)
    workers[id]?.account = .reconciled
  }

  /// Asks a version-1 supervisor to stop its exec and exit (one that predates `/retire` stops it when its own lease runs out), and
  /// removes its directory when nothing listens on its socket any more.
  nonisolated static func retireUnadopted(_ manifest: SupervisorManifest, directory: String) {
    guard manifest.socket == directory + "/control.sock" || manifest.socket == directory + "/s", manifest.nonce.count == 72,
          manifest.nonce.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return }
    let request = Array("PUT /retire HTTP/1.1\r\nHost: localhost\r\nX-Wuhu-Supervisor-Nonce: \(manifest.nonce)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    let sent = exec_unix_request(manifest.socket, request, request.count, Int32(controlDeadline / .milliseconds(1)))
    guard sent == -ECONNREFUSED || sent == -ENOENT else { return }
    removeSupervisorDirectory(directory)
  }

  func run() async {
    while !Task.isCancelled {
      await tick()
      do { try await clock.sleep(.milliseconds(100)) } catch { break }
    }
    await taskScope.close()
    transportScope.cancel()
  }

  /// Judges every worker by its lock, records what the dead ones dropped
  /// and forgets them, expires routes, sends the stops a leave or retirement owes, and keeps one current worker launched while
  /// the machine serves.
  func tick() async {
    let now = clock.now()
    for (id, worker) in workers {
      // A worker this agent launched may not hold its lock yet; until its first link, its running process says it is starting.
      let starting = worker.account == .launched && !worker.everLinked && now - worker.since < ExecWorker.firstLinkGrace && worker.pid.map(ExecSupervisor.running) != false
      // Died: what it last recorded, and whatever this agent routed to it that had not settled. Unless its inventory was never
      // read, those routes name everything it held.
      let routed = Set(routes.filter { $0.value.owner == .worker(id) && !$0.value.settled }.map(\.key))
      let liveness = WorkerDirectory.bury(WorkerDirectory.path(workers: directory, id), starting: starting, known: worker.account == .unreadable ? nil : routed, keep: { recordLost($0) })
      if liveness == .unaccounted { unaccounted.insert(id) }
      if liveness != .alive { forget(id) }
    }
    for (id, supervisor) in supervisors {
      var state = stat()
      if lstat(operations + "/" + id.uuidString, &state) == 0 {
        // A settled exec's supervisor would otherwise linger until its receipt expires.
        if let route = routes[id], route.settled, Self.released(route), !supervisor.retireAsked, let link = supervisor.link {
          supervisors[id]?.retireAsked = true
          let nonce = supervisor.manifest.nonce
          taskScope.bestEffort("supervisor-retire", within: Self.controlDeadline) { _ = try await Self.exchange(scope: self.transportScope, Request(url: URL(string: "http://supervisor/retire")!, method: .put), client: link.client, nonce: nonce, deadline: Self.controlDeadline, operation: id) }
        }
        continue
      }
      if !(routes[id]?.settled ?? false), !recordLost([id]) { continue }
      supervisor.link?.abort()
      supervisors.removeValue(forKey: id); routes.removeValue(forKey: id)
    }
    // A worker drops a receipt one retention window after its last request; its route goes with it, lost unless settled.
    for (id, route) in routes where route.owner != .supervisor && route.phase != .starting && now - route.lastRequest >= retention + .seconds(1) {
      if route.settled || recordLost([id]) { routes.removeValue(forKey: id) }
    }
    if service != .serving { stopUnverdicted() }
    if current == nil, service == .serving, now >= nextLaunch { await launchWorker() }
  }

  /// A worker that is gone: its link and routes go. What it dropped was recorded before its directory was removed.
  func forget(_ id: UUID) {
    guard let worker = workers.removeValue(forKey: id) else { return }
    worker.link?.abort()
    if current == id { current = nil }
    routes = routes.filter { $0.value.owner != .worker(id) }
    if worker.account == .launched, !worker.everLinked {
      launchBackoff = min(max(launchBackoff * 2, .milliseconds(100)), Self.launchBackoffCeiling)
      nextLaunch = clock.now() + launchBackoff
    }
  }

  func launchWorker() async {
    guard !launching else { return }
    launching = true
    defer { launching = false }
    let id = UUID()
    let path = WorkerDirectory.path(workers: directory, id)
    let manifest = WorkerManifest(
      machine: machine, worker: id, nonce: UUID().uuidString + UUID().uuidString, socket: socket, disclaimResponsibility: disclaimResponsibility ? true : nil,
      receiptRetentionMs: retention == OperationAgent.receiptRetention ? nil : Int(retention / .milliseconds(1)),
    )
    do {
      try WorkerDirectory.create(path, manifest)
      // Known before it runs, so its first dial is never refused as unknown.
      workers[id] = Worker(manifest: manifest, account: .launched, since: clock.now())
      if service == .serving { current = id }
      let pid = try await launch([executable, "machine-v2", "exec-worker", path])
      if workers[id] != nil { workers[id]?.pid = pid }
    } catch {
      if workers.removeValue(forKey: id) != nil, current == id { current = nil }
      WorkerDirectory.remove(path)
      launchBackoff = min(max(launchBackoff * 2, .milliseconds(100)), Self.launchBackoffCeiling)
      nextLaunch = clock.now() + launchBackoff
    }
  }

  // MARK: Links

  /// Admits a worker this agent knows, or a version-2 supervisor of a recovered operation, proved by its manifest nonce. A newer
  /// link from the same dialer replaces the older one. A recovered worker's first link reconciles its routes with its inventory.
  func link(_ hello: Rendezvous.Hello, client: FetchClient, abort: @escaping @Sendable () -> Void) throws(Rendezvous.Refusal) -> (generation: UInt64, reply: Rendezvous.Reply) {
    guard hello.protocol == Rendezvous.protocolName else { throw .unsupportedProtocol }
    if let id = hello.worker {
      guard let worker = workers[id] else { throw .unknownWorker }
      guard hello.machine == machine, worker.manifest.machine == machine else { throw .machineMismatch }
      guard Rendezvous.noncesMatch(hello.nonce, worker.manifest.nonce) else { throw .nonceMismatch }
      generations += 1
      worker.link?.abort()
      workers[id]?.connection = .linked(Link(client: client, generation: generations, abort: abort))
      switch worker.account {
      case .launched: launchBackoff = .zero
      case .inventoried, .unreadable: reconcile(id)
      case .reconciled: break
      }
      return (generations, .init(accepted: true, current: id == current))
    }
    guard let operation = hello.operation, let supervisor = supervisors[operation] else { throw .unknownOperation }
    guard hello.machine == supervisor.manifest.machine, supervisor.manifest.machine == machine else { throw .machineMismatch }
    guard Rendezvous.noncesMatch(hello.nonce, supervisor.manifest.nonce) else { throw .nonceMismatch }
    generations += 1
    supervisor.link?.abort()
    supervisors[operation]?.link = Link(client: client, generation: generations, abort: abort)
    return (generations, .init(accepted: true))
  }

  func unlink(_ hello: Rendezvous.Hello, generation: UInt64) {
    if let id = hello.worker, workers[id]?.link?.generation == generation { workers[id]?.connection = .dropped }
    if hello.worker == nil, let id = hello.operation, supervisors[id]?.link?.generation == generation { supervisors[id]?.link = nil }
  }

  /// The link to `owner` as it is now.
  func linked(_ owner: Owner, operation: UUID) -> (client: FetchClient, nonce: String)? {
    switch owner {
    case let .worker(id): workers[id].flatMap { worker in worker.link.map { ($0.client, worker.manifest.nonce) } }
    case .supervisor: supervisors[operation].flatMap { supervisor in supervisor.link.map { ($0.client, supervisor.manifest.nonce) } }
    }
  }

  /// The link to `owner`, waiting a little for it to (re)dial. Nil once the owner is gone.
  func link(to owner: Owner, operation: UUID) async throws -> (client: FetchClient, nonce: String)? {
    let until = clock.now() + Self.linkWait
    while true {
      if let link = linked(owner, operation: operation) { return link }
      switch owner {
      case let .worker(id): guard workers[id] != nil else { return nil }
      case .supervisor: guard supervisors[operation] != nil else { return nil }
      }
      guard clock.now() < until else { throw Unavailable.workerNotConnected.error(operation) }
      try await clock.sleep(.milliseconds(10))
    }
  }

  /// The linked current worker. A worker this agent launched gets its first-link grace to dial in (a cold start of the
  /// executable on a loaded host can take seconds); anything else gets the usual link wait.
  func currentWorker() async throws -> UUID {
    let until = clock.now() + Self.linkWait
    while true {
      guard service == .serving else { throw OperationError(.leaving) }
      if let id = current, workers[id]?.link != nil { return id }
      let launching = current.flatMap { workers[$0] }.map { $0.account == .launched && !$0.everLinked && clock.now() - $0.since < ExecWorker.firstLinkGrace } ?? false
      guard clock.now() < until || launching else { throw Unavailable.workerNotConnected.error(nil) }
      try await clock.sleep(.milliseconds(10))
    }
  }

  // MARK: Admission

  /// An id this backend answers for: routed, held by an unadopted supervisor, or recorded lost. Recovered inventories are
  /// complete for every live worker, so any other id is no worker's.
  func owns(_ id: UUID) -> Bool { routes[id] != nil || unadopted.contains(id) || lost.contains(id) }

  /// Every routed operation at its reservation; a recovered worker whose inventory is unreadable at the most a worker holds.
  func admissionUsage() -> ExternalUsage {
    var usage = ExternalUsage(operations: routes.mapValues(\.reservation))
    let unknown = workers.values.filter { $0.account == .unreadable }.count
    if unknown > 0 {
      let limits = OperationLimits()
      usage.receipts = unknown * limits.receipts
      usage.bufferBytes = unknown * limits.bufferBytes
    }
    return usage
  }

  static func released(_ route: Route) -> Bool {
    route.settled && ComputerKindSchemas.exec.outputChannels.allSatisfy { route.acknowledged.contains($0.name) }
  }

  // MARK: Leaving and retirement

  /// The machine is leaving: no worker is current and no start is routed, and every operation still running gets the standard
  /// stop. One whose owner is not linked now gets it when the owner redials.
  func leave() {
    if service == .serving { service = .leaving }
    current = nil
    stopUnverdicted()
  }

  /// Sends `stop` (reason `leaving`, or `retired` once retiring) to every operation without a verdict whose owner is linked.
  func stopUnverdicted() {
    let reason: StopReason = if case .retired = service { .retired } else { .leaving }
    for (id, route) in routes where route.phase == .running(stopping: false) {
      guard let link = linked(route.owner, operation: id) else { continue }
      routes[id]?.phase = .running(stopping: true)
      let owner = route.owner
      taskScope.bestEffort("worker-operation-stop", within: Self.controlDeadline) { await self.stop(id, owner: owner, link: link, reason: reason) }
    }
  }

  func stop(_ id: UUID, owner: Owner, link: (client: FetchClient, nonce: String), reason: StopReason) async {
    do {
      let request = Request(url: try url(id, "/stop"), method: .put, body: try .json(StopRequest(reason: reason.rawValue)))
      let (response, data) = try await Self.exchange(scope: self.transportScope, request, client: link.client, nonce: link.nonce, deadline: Self.controlDeadline, operation: id)
      try record(request, response, data, id, owner)
      if Self.unknownOperation(response, data) || response.status.code == 200 { return }
    } catch {}
    if routes[id]?.phase == .running(stopping: true) { routes[id]?.phase = .running(stopping: false) }
  }

  /// Asks each operation without a verdict for its snapshot, so a retirement sees the verdicts its stops caused.
  func pollUnverdicted() async {
    let targets = routes.filter { !$0.value.verdict }.map(\.key)
    await withTaskGroup(of: Void.self) { group in
      for id in targets { group.addTask { _ = await self.poll(id, "") } }
    }
  }

  /// Reads an ended operation's output channels to their ends and acknowledges its terminal on each, as the server would, so
  /// its worker releases it.
  func release(_ id: UUID) async {
    let until = clock.now() + Self.controlDeadline
    for channel in ComputerKindSchemas.exec.outputChannels.map(\.name) {
      var after: UInt64 = 0
      while clock.now() < until {
        guard let snapshot = await poll(id, "?channel=\(channel)&after=\(after)") else { return }
        let through = snapshot.through?.rawValue ?? after
        if snapshot.channelEnd, through == after {
          guard let token = snapshot.terminalToken else { return }
          _ = await poll(id, "?channel=\(channel)&after=\(after)&terminalAck=\(token.uuidString)")
          break
        }
        after = through
      }
    }
  }

  /// One poll of a routed operation, recorded like any forwarded answer; nil unless it answered with a snapshot.
  func poll(_ id: UUID, _ query: String) async -> OperationSnapshot? {
    guard let route = routes[id], let link = linked(route.owner, operation: id), let request = try? Request(url: url(id, query)),
          let (response, data) = try? await Self.exchange(scope: self.transportScope, request, client: link.client, nonce: link.nonce, deadline: Self.controlDeadline, operation: id)
    else { return nil }
    try? record(request, response, data, id, route.owner)
    guard response.status.code == 200 else { return nil }
    return try? JSONDecoder().decode(OperationSnapshot.self, from: data)
  }

  nonisolated func url(_ id: UUID, _ suffix: String) throws -> URL {
    guard let url = URL(string: "http://localhost/machine/v2/machines/\(machine)/operations/\(id.uuidString)\(suffix)") else { throw OperationError(.invalidConfiguration) }
    return url
  }

  /// Pending until no start is on its way, every recovered worker's inventory is known and every routed operation settled or
  /// was recorded lost; then drained, or the operations lost. A dead worker whose losses cannot be known fails it.
  func departureEvidence() throws -> ExternalDeparture {
    if let worker = unaccounted.first {
      throw OperationError(.requestDeadline, message: "leaveUnacknowledged", details: ["reason": "unreadableEvidence", "path": .string(WorkerDirectory.path(workers: directory, worker))])
    }
    guard service != .serving, !workers.values.contains(where: { $0.account == .unreadable }), routes.values.allSatisfy(\.settled) else { return .pending }
    reported = true
    return lost.isEmpty ? .drained : .leaseExpired(lost.sorted { $0.uuidString < $1.uuidString })
  }

  /// The agent stops serving the machine: no start is routed, every running operation gets the standard stop (reason
  /// `retired`), and every adopted supervisor its `/retire`. Waits at most `deadline` for their verdicts; a revoked machine,
  /// whose receipts nobody will read, then releases every ended operation. Last it cuts every worker's link; a worker that redials hears it is not current, and exits once its receipts lapse. Returns how many
  /// operations have no verdict yet. A turn-off after a reported departure clears the loss ledger.
  @discardableResult
  func retire(_ reason: SupervisorRetirement, deadline: Duration = retireDeadline) async -> Int {
    if service != .retired(.revoked) { service = .retired(reason) }
    current = nil
    let until = clock.now() + deadline
    stopUnverdicted()
    let targets = Array(supervisors.keys)
    await withTaskGroup(of: Void.self) { group in
      for id in targets {
        guard let link = linked(.supervisor, operation: id) else { continue }
        group.addTask { _ = try? await Self.exchange(scope: self.transportScope, Request(url: URL(string: "http://supervisor/retire")!, method: .put), client: link.client, nonce: link.nonce, deadline: Self.controlDeadline, operation: id) }
      }
    }
    while routes.values.contains(where: { !$0.verdict }), clock.now() < until {
      await pollUnverdicted()
      await tick()
      do { try await clock.sleep(.milliseconds(50)) } catch { break }
    }
    if reason == .revoked {
      let ended = routes.filter { $0.value.verdict && $0.value.owner != .supervisor }.map(\.key)
      await withTaskGroup(of: Void.self) { group in
        for id in ended { group.addTask { await self.release(id) } }
      }
    }
    for worker in workers.values { worker.link?.abort() }
    if reason == .turnedOff, reported, (try? WorkerDirectory.writeIDs(ledger, [])) != nil { lost = [] }
    return routes.values.filter { !$0.verdict }.count
  }

  // MARK: Requests

  nonisolated var handler: Handler { { await self.handle($0) } }

  nonisolated var external: ExternalKind {
    ExternalKind(
      descriptor: ComputerKindSchemas.exec,
      reservation: Self.fullReservation,
      handler: handler,
      usage: { await self.admissionUsage() },
      owns: { await self.owns($0) },
      leave: { await self.leave() },
      departure: { try await self.departureEvidence() },
    )
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

  func route(_ request: Request) async throws -> Response {
    let path = request.url.path.split(separator: "/").map(String.init)
    guard path.count >= 4, Array(path.prefix(3)) == ["machine", "v2", "machines"], path[3] == machine else { throw OperationError(.unknownMachine) }
    try await authorize(request, machine)
    if path.count == 4, request.method == .get {
      return try .json(MachineDescription(instance: instance, acceptingStarts: service == .serving, limits: .init(), kinds: [ComputerKindSchemas.exec]))
    }
    guard path.count >= 6, path[4] == "operations", let id = UUID(uuidString: path[5]) else { throw OperationError(.unknownOperation) }
    guard !unadopted.contains(id) else {
      throw UnknownOutcome.supervisorNotAdopted.error(id, message: "An earlier agent's supervisor holds this operation; its outcome is unknown")
    }
    if request.method == .post, path.count == 6 { return try await start(request, id) }
    if let route = routes[id] { return try await forward(request, id, to: route.owner) }
    if lost.contains(id) {
      throw UnknownOutcome.workerLost.error(id, message: "Its worker dropped this operation before it settled")
    }
    // Another worker's inventory may name it once that worker's can be read.
    if workers.values.contains(where: { $0.account == .unreadable }) { throw Unavailable.workerNotConnected.error(id) }
    if !unaccounted.isEmpty { throw UnknownOutcome.workerUnaccounted.error(id, message: "A dead worker whose inventory cannot be read may have dropped this operation") }
    throw OperationError(.unknownOperation)
  }

  func start(_ request: Request, _ id: UUID) async throws -> Response {
    guard service == .serving else { throw OperationError(.leaving) }
    guard !owns(id) else { throw OperationError(.operationExists) }
    let start = try await request.json(StartRequest.self, upTo: OperationLimits().inputBytes)
    guard start.kind == ComputerKindSchemas.exec.name else { throw OperationError(.unknownKind) }
    try JSONDecoder().decode(ExecInput.self, from: Data(start.input.jsonString().utf8)).validate()
    let worker = try await currentWorker()
    guard !owns(id) else { throw OperationError(.operationExists) }
    // Routed in the same actor turn as the service check, so a leave or retirement waits for it.
    routes[id] = Route(owner: .worker(worker), lastRequest: clock.now())
    var forwarded = request; forwarded.body = try .json(start)
    // A start whose answer was lost may be running: its route stays. One the worker refused is forgotten.
    defer { if routes[id]?.phase == .starting { routes[id]?.phase = .running(stopping: false) } }
    let response = try await forward(forwarded, id, to: .worker(worker))
    if !(200 ..< 300).contains(response.status.code), response.status.code != 409, routes[id]?.owner == .worker(worker) { routes.removeValue(forKey: id) }
    return response
  }

  func forward(_ request: Request, _ id: UUID, to owner: Owner) async throws -> Response {
    guard let link = try await link(to: owner, operation: id) else { throw OperationError(.unknownOperation) }
    routes[id]?.lastRequest = clock.now()
    let (response, data) = try await Self.exchange(scope: self.transportScope, request, client: link.client, nonce: link.nonce, deadline: Self.requestDeadline, operation: id)
    try record(request, response, data, id, owner)
    return response
  }

  /// What a forwarded answer says about its operation. An answer that outlived its route changes nothing. A worker that says
  /// it does not know an operation last seen unsettled dropped it unsettled.
  func record(_ request: Request, _ response: Response, _ data: Data, _ id: UUID, _ owner: Owner) throws {
    guard var route = routes[id], route.owner == owner else { return }
    if Self.unknownOperation(response, data) {
      if route.phase != .starting, owner != .supervisor, route.settled || recordLost([id]) { routes.removeValue(forKey: id) }
      return
    }
    let path = request.url.path.split(separator: "/")
    // An input write answers with its channel's state, not a snapshot.
    guard response.status.code == 200 || response.status.code == 201, path.count == 6 || path[6] != "inputs" else { return }
    let snapshot = try JSONDecoder().decode(OperationSnapshot.self, from: data)
    guard snapshot.operation == id else { throw OperationError(.invalidResponse) }
    // Answers can arrive out of order; one from before the verdict says nothing new once a verdict was seen.
    guard snapshot.verdict != nil || !route.verdict else { return }
    if let bytes = snapshot.bufferReservationBytes {
      guard (0 ... Self.windows).contains(bytes) else { throw OperationError(.unsupportedProtocol) }
      route.reservation = bytes + (snapshot.finalOffsets.count == ComputerKindSchemas.exec.outputChannels.count ? 0 : Self.readStaging)
    }
    if snapshot.verdict != nil, !route.verdict { route.phase = .ended }
    let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    if response.status.code == 200, request.method == .get, path.count == 6, snapshot.verdict != nil, let token = snapshot.terminalToken,
       let acknowledged = query.first(where: { $0.name == "terminalAck" })?.value, UUID(uuidString: acknowledged) == token
    {
      route.acknowledged.insert(query.first(where: { $0.name == "channel" })?.value ?? "")
    }
    if snapshot.verdict != nil, snapshot.outputConsumed, !route.acknowledged.isEmpty { route.phase = .settled }
    if route.settled { route.reservation = 0 }
    // The worker drops a released operation at once; so does its route.
    if owner != .supervisor, Self.released(route) { routes.removeValue(forKey: id) } else { routes[id] = route }
  }

  static func unknownOperation(_ response: Response, _ data: Data) -> Bool {
    response.status.code == 404 && (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.code == .unknownOperation
  }

  /// One request over a link, its answer read whole, bounded by `deadline`.
  static func exchange(scope: TaskScope, _ request: Request, client: FetchClient, nonce: String, deadline: Duration, operation: UUID?) async throws -> (Response, Data) {
    let query = request.url.query.map { "?" + $0 } ?? ""
    guard let url = URL(string: "http://localhost" + request.url.path + query) else { throw OperationError(.invalidConfiguration) }
    var local = request; local.url = url
    local.headers["Host"] = "localhost"
    local.headers["X-Wuhu-Supervisor-Nonce"] = nonce
    let request = local
    let (answers, reply) = AsyncThrowingStream<(Response, Data), any Error>.makeStream(bufferingPolicy: .bufferingOldest(1))
    let work = try scope.run("worker-exchange") {
      do {
        let response = try await client(request)
        let data = try await response.body.bytes(upTo: OperationLimits.responseBytes)
        reply.yield((Response(status: response.status, headers: response.headers, body: .bytes(data, contentType: response.body.contentType)), Data(data)))
        reply.finish()
      } catch { reply.finish(throwing: error) }
    }
    defer { work.cancel() }
    do {
      return try await withDeadline(deadline, clock: ContinuousClock()) {
        for try await answer in answers { return answer }
        throw CancellationError()
      }
    } catch is DeadlineExceeded {
      throw Unavailable.supervisorTimeout.error(operation)
    }
  }
}

/// Removes a version-1 supervisor's directory: its manifest and either socket name.
func removeSupervisorDirectory(_ directory: String) {
  for name in ["manifest.json", "control.sock", "s"] { _ = unlink(directory + "/" + name) }
  _ = rmdir(directory)
}
