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
import Fetch
import class NIOPosix.MultiThreadedEventLoopGroup
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationRuntime.AnyOperationKind
import class OperationRuntime.OperationAgent
import typealias Serve.Handler

/// One exec worker's private directory, `<machine directory>/workers/<worker>`: its manifest, the `.lock` it holds for its whole
/// life, and `operations.json`, its inventory. A newer agent marks a worker it recovers `superseded` before it reads that inventory.
struct WorkerManifest: Codable, Equatable, Sendable {
  let machine: String
  let worker: UUID
  let nonce: String
  let socket: String
  var disclaimResponsibility: Bool? = nil
  /// How long the worker keeps a receipt after its caller's last request; absent in production (the runtime's 60 seconds).
  var receiptRetentionMs: Int? = nil
}

/// What a worker holds, as it last wrote it: every retained operation (and every start it admitted, written before the start
/// runs), the ones among them not yet settled, and the ones it dropped before they settled.
struct WorkerInventory: Codable, Equatable, Sendable {
  var retained: Set<UUID> = []
  var unsettled: Set<UUID> = []
  var lost: Set<UUID> = []

  /// What the worker's death or exit leaves unsettled for good.
  var dropped: Set<UUID> { unsettled.union(lost) }
}

enum WorkerDirectory {
  /// The most an inventory or the loss ledger may hold on disk. Writers refuse more, so a reader never meets a larger file of ours.
  static let evidenceBytes = 1 << 20

  /// Evidence that exists but cannot be read: an error, never an empty record.
  static func unreadable(_ path: String) -> OperationError {
    OperationError(.invalidConfiguration, message: "unreadableEvidence", details: ["path": .string(path)])
  }

  static func path(workers: String, _ id: UUID) -> String { workers + "/" + id.uuidString }

  /// The machine's private directory holds `ctl.sock` and `workers/`.
  static func socket(directory: String) -> String {
    Rendezvous.socketPath(operationsDirectory: Rendezvous.machineDirectory(operationsDirectory: directory))
  }

  static func create(_ directory: String, _ manifest: WorkerManifest) throws {
    guard mkdir(directory, 0o700) == 0 else { throw OperationError(errno == EEXIST ? .operationExists : .invalidConfiguration, details: ["path": .string(directory)]) }
    try writeFile(directory + "/manifest.json", JSONEncoder().encode(manifest))
  }

  static func load(_ directory: String) throws -> WorkerManifest {
    let manifest = try JSONDecoder().decode(WorkerManifest.self, from: readFile(directory + "/manifest.json"))
    guard directory.hasSuffix("/" + manifest.worker.uuidString), manifest.socket == socket(directory: directory),
          !manifest.machine.isEmpty, manifest.nonce.count == 72 else { throw OperationError(.invalidConfiguration, message: "Malformed exec worker manifest", details: ["path": .string(directory)]) }
    return manifest
  }

  /// The worker's own lock: held from its start until it exits. Nil when another process holds it.
  static func lock(_ directory: String, create: Bool) -> Int32? {
    let fd = exec_lock_file(directory + "/.lock", create ? 1 : 0)
    return fd >= 0 ? fd : nil
  }

  /// What a directory says about its worker, judged by its lock alone: a dead worker's lock is free.
  enum Liveness: Equatable {
    case alive
    /// Exited having removed its directory, or never got as far as its manifest; nothing was lost.
    case gone
    /// Died, or exited leaving its inventory: these operations went unsettled.
    case dead(Set<UUID>)
    /// Died, and neither its inventory nor the caller can say what it dropped; its directory stays as the evidence.
    case unaccounted
  }

  /// Probes and, unless the worker is alive, removes its directory while holding its lock, so no late writer races the removal.
  /// `keep` records what a dead worker dropped (its inventory's, and `known`: what the caller routed to it unsettled, when the
  /// caller's routes name everything it held) before the directory goes; when it fails the directory stays, reported alive, for
  /// the next probe. `starting` is a worker this agent launched that may not have taken its lock yet.
  static func bury(_ directory: String, starting: Bool = false, known: Set<UUID>? = nil, keep: (Set<UUID>) -> Bool = { _ in true }) -> Liveness {
    var state = stat()
    guard lstat(directory, &state) == 0 else { return .gone }
    let fd = lock(directory, create: false)
    if fd == nil {
      guard errno == ENOENT || access(directory + "/.lock", F_OK) != 0 else { return .alive }
      if starting { return .alive }
    }
    defer { if let fd { exec_close(fd) } }
    guard lstat(directory + "/manifest.json", &state) == 0 else { remove(directory); return .gone }
    let dropped: Set<UUID>
    if let inventory = try? inventory(directory) { dropped = inventory.dropped.union(known ?? []) }
    else if let known { dropped = known }
    else { return .unaccounted }
    guard keep(dropped) else { return .alive }
    remove(directory)
    return .dead(dropped)
  }

  static func remove(_ directory: String) {
    for name in ["operations.json", "operations.json.tmp", "superseded", "manifest.json", ".lock", ".spawn.lock"] { _ = unlink(directory + "/" + name) }
    _ = rmdir(directory)
  }

  /// The worker's inventory: empty when it never wrote one (it admitted no start).
  static func inventory(_ directory: String) throws -> WorkerInventory {
    try evidence(directory + "/operations.json", empty: WorkerInventory())
  }

  /// Replaces the inventory whole: written beside it, then renamed. One that cannot be written is spoiled instead, so no reader
  /// takes the last one written for the worker's present.
  static func writeInventory(_ directory: String, _ inventory: WorkerInventory) throws {
    let path = directory + "/operations.json"
    do {
      _ = unlink(path + ".tmp")
      try writeFile(path + ".tmp", JSONEncoder().encode(inventory), sync: false)
      guard rename(path + ".tmp", path) == 0 else { throw unreadable(path) }
    } catch {
      let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
      if fd >= 0 { _ = close(fd) }
      throw error
    }
  }

  /// Marks a recovered worker: it admits no start from here on. The agent marks before it reads the inventory, and the worker
  /// checks after it writes a claim, so every start the worker runs is in the inventory the agent reads.
  static func supersede(_ directory: String) {
    let fd = open(directory + "/superseded", O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    if fd >= 0 { _ = close(fd) }
  }

  static func superseded(_ directory: String) -> Bool { access(directory + "/superseded", F_OK) == 0 }

  /// A set of ids: empty when the file does not exist.
  static func ids(_ path: String) throws -> Set<UUID> { try Set(evidence(path, empty: [UUID]())) }

  /// A file of evidence: `empty` when it does not exist, an `unreadableEvidence` error when it exists and cannot be read whole.
  static func evidence<T: Decodable>(_ path: String, empty: T) throws -> T {
    var state = stat()
    guard lstat(path, &state) == 0 else {
      guard errno == ENOENT else { throw unreadable(path) }
      return empty
    }
    guard let decoded = try? JSONDecoder().decode(T.self, from: readFile(path)) else { throw unreadable(path) }
    return decoded
  }

  /// Replaces `path` whole and durably (write beside it, sync, then rename); an empty set removes it.
  static func writeIDs(_ path: String, _ ids: Set<UUID>) throws {
    guard !ids.isEmpty else { _ = unlink(path); return }
    _ = unlink(path + ".tmp")
    try writeFile(path + ".tmp", JSONEncoder().encode(ids.sorted { $0.uuidString < $1.uuidString }))
    guard rename(path + ".tmp", path) == 0 else { throw OperationError(.invalidConfiguration, details: ["path": .string(path)]) }
  }

  static func writeFile(_ path: String, _ data: Data, sync: Bool = true) throws {
    guard data.count <= evidenceBytes else { throw OperationError(.invalidConfiguration, message: "evidenceFull", details: ["path": .string(path)]) }
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw OperationError(.invalidConfiguration, details: ["path": .string(path)]) }
    defer { _ = close(fd) }
    let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    guard count == data.count, !sync || fsync(fd) == 0 else { throw OperationError(.invalidConfiguration, details: ["path": .string(path)]) }
  }

  static func readFile(_ path: String) throws -> Data {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw OperationError(.invalidConfiguration, details: ["path": .string(path)]) }
    defer { _ = close(fd) }
    var state = stat()
    guard fstat(fd, &state) == 0, state.st_uid == getuid(), state.st_mode & 0o777 == 0o600, state.st_mode & S_IFMT == S_IFREG,
          state.st_size > 0, state.st_size <= evidenceBytes else { throw OperationError(.invalidConfiguration, details: ["path": .string(path)]) }
    var bytes = [UInt8](repeating: 0, count: Int(state.st_size))
    guard read(fd, &bytes, bytes.count) == bytes.count else { throw OperationError(.invalidConfiguration, details: ["path": .string(path)]) }
    return Data(bytes)
  }
}

/// The worker's one lifetime rule: it exits once it holds no operations and it is not the linked, current worker.
actor ExecWorker {
  let manifest: WorkerManifest
  let directory: String
  let agent: OperationAgent
  let clock: OperationClock
  let began: Duration
  var standing = Standing.awaitingLink
  /// Admitted starts not yet answered, in the inventory from before they run until the runtime holds them, each with the
  /// requests waiting for its answer.
  var claims: [UUID: [AsyncStream<Never>.Continuation]] = [:]
  var recorded: WorkerInventory?
  private let taskScope = TaskScope()
  var recording: Task<Void, Never>?

  /// How long a launched worker waits for its first link before it gives up on an agent that is gone.
  static let firstLinkGrace: Duration = .seconds(10)

  /// Where the worker stands with the machine's agent.
  enum Standing: Equatable {
    case awaitingLink
    /// Only the current worker admits starts.
    case linked(current: Bool)
    /// Was linked; redialing.
    case unlinked
    /// Refused for good: it never redials.
    case refused(Rendezvous.Refusal)
  }

  init(manifest: WorkerManifest, directory: String, clock: OperationClock = .continuous) throws {
    self.manifest = manifest; self.directory = directory; self.clock = clock; began = clock.now()
    let retention = manifest.receiptRetentionMs.map { Duration.milliseconds($0) } ?? OperationAgent.receiptRetention
    agent = try OperationAgent(machine: manifest.machine, kinds: [AnyOperationKind(ExecKind(clock: clock, disclaimResponsibility: manifest.disclaimResponsibility == true, receiptsDirectory: directory))], clock: clock, receiptRetention: retention, authorize: { request, _ in
      guard request.headers["X-Wuhu-Supervisor-Nonce"] == manifest.nonce else { throw OperationError(.machineNotAuthorized) }
    })
  }

  /// The operation protocol. A start runs only on the linked, current worker, and only once its id is in the inventory; a
  /// terminal acknowledgement, which can release an operation, is recorded before its answer goes back.
  nonisolated var handler: Handler {
    { [agent, manifest] request in
      let path = request.url.path.split(separator: "/")
      guard request.method == .post, path.count == 6, let id = UUID(uuidString: String(path[5])),
            Rendezvous.noncesMatch(request.headers["X-Wuhu-Supervisor-Nonce"] ?? "", manifest.nonce)
      else {
        // A request for a start still being admitted waits for its answer: the worker never says it does not know an id it took.
        if path.count >= 6, let id = UUID(uuidString: String(path[5])) { await self.admitted(id) }
        let response = try await agent.handler(request)
        let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if query.contains(where: { $0.name == "terminalAck" }) { await self.record() }
        return response
      }
      guard await self.claim(id) else {
        let error = Unavailable.workerNotCurrent.error(id)
        return try .json(ErrorEnvelope(error), status: .init(code: error.statusCode))
      }
      let response: Response
      do { response = try await agent.handler(request) } catch { await self.unclaim(id); throw error }
      await self.unclaim(id)
      return response
    }
  }

  /// Admits a start: writes its id into the inventory, then checks that no newer agent superseded this worker in between.
  func claim(_ id: UUID) async -> Bool {
    guard standing == .linked(current: true), claims[id] == nil else { return false }
    claims[id] = []
    await record()
    let superseded = WorkerDirectory.superseded(directory)
    if superseded, standing == .linked(current: true) { standing = .linked(current: false) }
    guard recorded?.retained.contains(id) == true, !superseded, standing == .linked(current: true) else {
      await unclaim(id)
      return false
    }
    return true
  }

  /// Returns once `id` is not being admitted (or the caller is cancelled).
  func admitted(_ id: UUID) async {
    guard claims[id] != nil else { return }
    let (answered, waiter) = AsyncStream<Never>.makeStream()
    claims[id]?.append(waiter)
    for await _ in answered {}
  }

  func unclaim(_ id: UUID) async {
    let waiters = claims.removeValue(forKey: id) ?? []
    await record()
    for waiter in waiters { waiter.finish() }
  }

  /// Writes the inventory when it changed. Writes run one at a time, each reading the runtime afresh.
  func record() async {
    let previous = recording
    let task = try? taskScope.run("worker-inventory") { await previous?.value; await self.write() }
    recording = task
    await task?.value
  }

  func write() async {
    let held = await agent.inventory()
    let inventory = WorkerInventory(retained: held.retained.union(claims.keys), unsettled: held.unsettled.union(claims.keys), lost: held.lost)
    guard inventory != recorded else { return }
    recorded = (try? WorkerDirectory.writeInventory(directory, inventory)).map { inventory }
  }

  /// The inventory is on disk before the agent reads it at this hello.
  func hello() async -> Rendezvous.Hello {
    await record()
    return .init(protocol: Rendezvous.protocolName, machine: manifest.machine, worker: manifest.worker, nonce: manifest.nonce)
  }

  func accepted(_ reply: Rendezvous.Reply) {
    standing = .linked(current: reply.current == true && !WorkerDirectory.superseded(directory))
  }

  func unlinked() { standing = .unlinked }

  /// A permanent refusal: the worker stops its running execs and never redials; it exits under the same rule.
  func refuse(_ refusal: Rendezvous.Refusal) async {
    standing = .refused(refusal)
    await agent.stopRunning(reason: StopReason.refused.rawValue)
  }

  func shouldExit() async -> Bool {
    switch standing {
    case .linked(current: true): return false
    case .awaitingLink where clock.now() - began < Self.firstLinkGrace: return false
    default: break
    }
    guard claims.isEmpty else { return false }
    return !(await agent.hasRetainedOperations())
  }

  /// Removes the directory, or leaves it with an inventory naming what it dropped unsettled.
  func finish() async {
    await taskScope.close()
    let held = await agent.inventory()
    let dropped = held.unsettled.union(held.lost)
    guard !dropped.isEmpty else { WorkerDirectory.remove(directory); return }
    // One it cannot write is left spoiled: unreadable, never empty.
    try? WorkerDirectory.writeInventory(directory, WorkerInventory(lost: dropped))
  }
}

extension ExecSupervisor {
  /// `wuhu machine-v2 exec-worker <directory>`: serves exec operations for the machine's agent over `ctl.sock` until the lifetime
  /// rule says it is done.
  public static func runWorker(directory: String) async throws {
    let manifest = try WorkerDirectory.load(directory)
    guard let lock = WorkerDirectory.lock(directory, create: true) else { throw OperationError(.invalidConfiguration, message: "Another process owns this exec worker") }
    defer { exec_close(lock) }
    try ProcessReceipt.write(getpid(), descriptor: lock)
    _ = signal(SIGPIPE, SIG_IGN)
    let worker = try ExecWorker(manifest: manifest, directory: directory)
    let events = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    await serve(worker, events: events)
    await worker.finish()
    try? await events.shutdownGracefully()
  }

  static func serve(_ worker: ExecWorker, events: MultiThreadedEventLoopGroup, clock: OperationClock = .continuous) async {
    await withTaskGroup(of: Void.self) { group in
      group.addTask { await worker.agent.run() }
      group.addTask {
        let refusal = await Rendezvous.redial(
          path: worker.manifest.socket, hello: { await worker.hello() }, group: events, limits: Rendezvous.workerLimits, handler: worker.handler,
          accepted: { await worker.accepted($0) }, unlinked: { await worker.unlinked() },
        )
        if let refusal { await worker.refuse(refusal) }
        // Without a link there is nothing more to serve; the lifetime loop decides when to exit.
        while !Task.isCancelled { do { try await clock.sleep(.seconds(3600)) } catch { return } }
      }
      group.addTask {
        while !Task.isCancelled {
          do { try await clock.sleep(.milliseconds(100)) } catch { return }
          await worker.record()
          if await worker.shouldExit() { return }
        }
      }
      _ = await group.next()
      await worker.agent.shutdown(); group.cancelAll()
    }
  }
}
