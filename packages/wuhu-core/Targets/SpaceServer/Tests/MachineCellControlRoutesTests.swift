import Crypto
import Dependencies
import DeterministicDependencies
import Dispatch
import Fetch
import FetchTunnel
import GRDB
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MachineContract
import OperationProtocol
import Scratch
import Serve
@testable import SpaceCore
@testable import SpaceServer
import Synchronization
import Testing
import Wuwei

@Suite(.deterministicDependencies) struct MachineCellControlRoutesTests {
  @Test(arguments: ["revoke", "rotate", "selfRevoke"])
  func credentialResetOnAnotherWorkerClosesTheOwningBox(action: String) async throws {
    let folder = try ScratchFolder("machine-cross-worker-revoke")
    defer { folder.remove() }
    let file = folder.url.appendingPathComponent("space.sqlite")
    let owner = try Space.open(file: file)
    let key = Curve25519.Signing.PrivateKey()
    let enrolled = try await owner.enrollMachineV2(name: "box", group: .shared, pubkey: key.pubkeyLabel)
    let machine = enrolled.machine.id
    let id = MachineCell.ID(machine.rawValue)
    let opened = Gate(), closed = Gate()
    let closes = Mutex(0)
    let socket = try #require(owner.worker.attach(BoxSocket.self, to: id, opening: .init(connection: UUID(), pubkey: key.pubkeyLabel, streams: 32)) {
      switch $0 {
      case .frame: opened.open()
      case .closed: closes.withLock { $0 += 1 }; closed.open()
      }
    })
    defer { socket.close() }
    await opened.wait()
    let other = try Space.open(file: file)
    let hub = MachineHub(space: other)
    let handler = SpaceServer.configuredHandler(space: other, hub: hub, dev: true, listenerRoutes: machineListenerRoutes(space: other, hub: hub))
    let request: Request
    if action == "selfRevoke" {
      request = try await MachineV2TunnelTests().signed(handler, "/v1/machine-v2/\(machine.rawValue)/revoke", key: key, machine: machine)
    } else {
      request = Request(url: URL(string: "https://space.test/v1/machine/\(machine.rawValue)/\(action)")!, method: .post)
    }
    guard case let .response(response) = try await handler(request) else { Issue.record("control must be HTTP"); return }
    #expect(response.status == .ok)
    #expect(try await other.machine(pubkey: key.pubkeyLabel) == nil)
    #expect(owner.worker.hasMail(for: id.recipient))
    owner.worker.start()
    try await until("the owning worker closes the revoked box", timeout: .seconds(4)) { closed.isOpen }
    do {
      try await MachineHub(space: owner).authorize(.init(pubkey: key.pubkeyLabel, machines: [machine.rawValue]))
      Issue.record("redial with the purged key was authorized")
    } catch let error as OperationError { #expect(error.code == .machineNotAuthorized) }
    other.worker.start()
    await owner.worker.quiesce()
    owner.worker.release()
    await other.worker.quiesce()
    #expect(!other.worker.hasMail(for: id.recipient))
    #expect(closes.withLock { $0 } == 1)
    try await other.close()
    try await owner.close()
  }

  @Test(arguments: [false, true])
  func capturedConnectionRejectsStartWithRevocationMailStillPending(file: Bool) async throws {
    let folder = try ScratchFolder("machine-captured-connection")
    defer { folder.remove() }
    let database = folder.url.appendingPathComponent("space.sqlite")
    let space = try Space.open(file: database)
    let key = Curve25519.Signing.PrivateKey()
    let machine = try await space.enrollMachineV2(name: "box", group: .shared, pubkey: key.pubkeyLabel).machine
    let id = MachineCell.ID(machine.id.rawValue)
    let hub = MachineHub(space: space)
    let starts = Mutex(0)
    let link = try #require(await hub.boxLink(.init(pubkey: key.pubkeyLabel, machines: [machine.id.rawValue]), streams: 32))
    let other = try Space.open(file: database)
    let ended = Gate()
    let instance = UUID()
    let client = FetchClient { request in
      var response: Response
      if request.method == .get, !request.url.path.contains("/operations/") {
        response = try Response.json(MachineDescription(instance: instance, acceptingStarts: true, limits: .init(), kinds: [ComputerKindSchemas.exec, ComputerKindSchemas.stat]))
      } else {
        starts.withLock { $0 += 1 }
        response = try Response.json(ErrorEnvelope(.init(.unknownOperation)), status: .notFound)
      }
      response.headers[.init("X-Wuhu-Request-ID")!] = request.headers["X-Wuhu-Request-ID"]
      response.headers[.init("X-Wuhu-Correlation-ID")!] = request.headers["X-Wuhu-Correlation-ID"]
      response.headers[.init("X-Wuhu-Agent-Instance")!] = instance.uuidString
      return response
    }
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await link.run(client: client); ended.open() }
      defer { link.close(); tasks.cancelAll() }
      try await until("the captured connection commits its description", timeout: .seconds(4)) {
        try await space.machineDescription(machine.id) != nil
      }
      let captured = try #require(space.worker.cell(id).box?.id)
      // The cold writer posts real mail; the owner has no scan running to deliver it.
      _ = try await other.resetCredentials(account: machine.account)
      #expect(try await space.machine(pubkey: key.pubkeyLabel) == nil)
      #expect(space.worker.hasMail(for: id.recipient))
      #expect(space.worker.cell(id).box?.id == captured)
      if file {
        let client = MachineFileClient(space: space, machine: machine.id, caller: nil)
        do {
          _ = try await client.call(.init(kind: "stat.v1", input: ["path": "/must-not-start"]))
          Issue.record("File START used the captured purged key")
        } catch let error as OperationError {
          #expect(error.code == .machineNotAuthorized)
        }
      } else {
        let record = try await space.reserveExec(machine: machine.id)
        var exec = try #require(try await space.execRequest(record.id))
        exec.argv = ["must-not-start"]
        let exits = AsyncStream<ExecFinished>.makeStream()
        let stream = try #require(space.worker.attach(ExecStream.self, to: id, opening: .init(exec: exec, nonce: UUID())) {
          if case let .frame(.exit(exit)) = $0 { exits.continuation.yield(exit) }
        })
        defer { stream.close(); exits.continuation.finish() }
        var iterator = exits.stream.makeAsyncIterator()
        let exit = try #require(await iterator.next())
        #expect(exit.error?.code == .machineNotAuthorized)
      }
      #expect(starts.withLock { $0 } == 0)
      #expect(space.worker.cell(id).box?.id == captured)
      #expect(space.worker.hasMail(for: id.recipient))
      #expect(!ended.isOpen)
      space.worker.poke(id.recipient)
      await ended.wait()
      #expect(space.worker.cell(id).box == nil)
      #expect(!space.worker.hasMail(for: id.recipient))
    }
    try await other.close()
    try await space.close()
  }

  @Test func revocationCloseMailEndsTheCapturedTunnel() async throws {
    let space = try Space.inMemory()
    let key = Curve25519.Signing.PrivateKey()
    let machine = try await space.enrollMachineV2(name: "box", group: .shared, pubkey: key.pubkeyLabel).machine
    let hub = MachineHub(space: space)
    let credential = MachineHub.Credential(pubkey: key.pubkeyLabel, machines: [machine.id.rawValue])
    let box = try #require(await hub.boxLink(credential, streams: 32))
    let incoming = AsyncStream<Bytes>.makeStream()
    let receiving = Gate(), aborted = Gate(), ended = Gate()
    let transport = TunnelTransport(receive: {
      receiving.open()
      for await bytes in incoming.stream { return bytes }
      return nil
    }, send: { _ in }, abort: { incoming.continuation.finish(); aborted.open() })
    await withTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await hub.run(credential, transport: transport, boxLink: box); ended.open() }
      defer { box.close(); incoming.continuation.finish(); tasks.cancelAll() }
      await receiving.wait()
      do {
        let handler = SpaceServer.configuredHandler(space: space, hub: hub, dev: true)
        let request = Request(url: URL(string: "https://space.test/v1/machine/\(machine.id.rawValue)/revoke")!, method: .post)
        guard case let .response(response) = try await handler(request) else { Issue.record("Revoke must be HTTP"); return }
        #expect(response.status == .ok)
        await ended.wait()
        #expect(aborted.isOpen)
        #expect(space.worker.cell(MachineCell.ID(machine.id.rawValue)).box == nil)
        await #expect(throws: OperationError(.machineNotAuthorized)) { try await hub.authorize(credential) }
      } catch { Issue.record("Revocation failed: \(error)") }
    }
    try await space.close()
  }

  @Test func revocationDeliveredBeforeBoxAttachmentNeverGreetsTheCapturedTunnel() async throws {
    let space = try Space.inMemory()
    let key = Curve25519.Signing.PrivateKey()
    let machine = try await space.enrollMachineV2(name: "box", group: .shared, pubkey: key.pubkeyLabel).machine
    let id = MachineCell.ID(machine.id.rawValue)
    let writer = await space.writer
    let database = try WuweiDatabase(writer: writer)
    let scheduler = HeldBoxAttachmentScheduler()
    let worker = Worker(id: "held-box-attachment", storage: .shared(database), scheduler: scheduler, registrations: [.cell(MachineCell.self)])
    let buffers = MachineBuffers(worker: worker.id)
    worker.provide(buffers)
    _ = try await worker.call(id) { cell in
      _ = try cell.ensurePresence()
      return true
    }
    await scheduler.drain()
    scheduler.holdNextTask()
    let hub = MachineHub(space: space)
    let credential = MachineHub.Credential(pubkey: key.pubkeyLabel, machines: [machine.id.rawValue])
    let link = BoxLink(worker: worker, machine: machine.id.rawValue, pubkey: key.pubkeyLabel, connection: UUID(), streams: 32, buffers: buffers, authorizeStart: {
      try await hub.authorize(credential)
    }, prepare: { _ in preconditionFailure("describe-only fixture") })
    let box = try #require(link)
    #expect(scheduler.heldTaskCount == 1)
    let incoming = AsyncStream<Bytes>.makeStream()
    let receiving = Gate(), aborted = Gate(), ended = Gate(), greetingSent = Gate()
    let sent = Mutex(0)
    let transport = TunnelTransport(receive: {
      receiving.open()
      for await bytes in incoming.stream { return bytes }
      return nil
    }, send: { _ in sent.withLock { $0 += 1 }; greetingSent.open() }, abort: { incoming.continuation.finish(); aborted.open() })
    try await withThrowingTaskGroup(of: Void.self) { tasks in
      tasks.addTask { await hub.run(credential, transport: transport, boxLink: box); ended.open() }
      defer { scheduler.releaseHeldTasks(); box.close(); incoming.continuation.finish(); tasks.cancelAll() }
      await receiving.wait()
      let handler = SpaceServer.configuredHandler(space: space, hub: hub, dev: true)
      let request = Request(url: URL(string: "https://space.test/v1/machine/\(machine.id.rawValue)/revoke")!, method: .post)
      guard case let .response(response) = try await handler(request) else { Issue.record("Revoke must be HTTP"); return }
      #expect(response.status == .ok)
      #expect(try await space.machine(pubkey: key.pubkeyLabel) == nil)
      #expect(worker.hasMail(for: id.recipient))
      worker.poke(id.recipient)
      await scheduler.drain()
      let recipient = id.description
      let mail = try await writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM wuwei_mail WHERE recipient = ?", arguments: [recipient])!
      }
      try #require(mail == 0)
      #expect(!worker.hasMail(for: id.recipient))
      #expect(scheduler.heldTaskCount == 1)
      #expect(worker.cell(id).box == nil)
      #expect(sent.withLock { $0 } == 0)
      scheduler.releaseHeldTasks()
      await scheduler.drain()
      let greeted = try await worker.call(id) { $0.box != nil }
      #expect(!greeted, "A revoked pending attachment must close without greeting")
      if greeted { await greetingSent.wait(); box.close() }
      await ended.wait()
      #expect(aborted.isOpen)
      let greetingFrames = sent.withLock { $0 }
      #expect(greetingFrames == 0)
      await scheduler.drain()
    }
    await worker.quiesce()
    worker.release()
    await scheduler.drain()
    try database.close()
    try await space.close()
  }

  @Test func killOnNonhostingWorkerIsAcceptedAndDeliveredAsMail() async throws {
    let folder = try ScratchFolder("machine-cross-worker-kill")
    defer { folder.remove() }
    let file = folder.url.appendingPathComponent("space.sqlite")
    let owner = try Space.open(file: file)
    let machine = try await owner.addMachineV2(name: "box").machine.id
    let exec = try await owner.reserveExec(machine: machine)
    let other = try Space.open(file: file)
    let server = TestServer(space: other, clock: ContinuousClock())
    let response = try await server.http(.post, "/v1/exec/\(exec.id.rawValue)/kill")
    #expect(response.status == .ok)
    owner.worker.start()
    try await until("the owning worker applies stop mail", timeout: .seconds(4)) {
      try await owner.execRecord(exec.id)?.terminal != nil
    }
    #expect(try await owner.execRecord(exec.id)?.terminal == .cancelled)
    try await other.close()
    try await owner.close()
  }

  @Test func deleteOnNonhostingWorkerCommitsAndDeliversToTheOwner() async throws {
    let folder = try ScratchFolder("machine-cross-worker-delete")
    defer { folder.remove() }
    let file = folder.url.appendingPathComponent("space.sqlite")
    let owner = try Space.open(file: file)
    let machine = try await owner.addMachineV2(name: "box").machine.id
    _ = try await owner.reserveExec(machine: machine)
    let other = try Space.open(file: file)
    let server = TestServer(space: other, clock: ContinuousClock())
    let response = try await server.http(.delete, "/v1/machine/\(machine.rawValue)")
    #expect(response.status == .ok)
    #expect(try await owner.machine(machine) == nil)
    #expect(owner.worker.hasMail(for: MachineCell.ID(machine.rawValue).recipient))
    owner.worker.start()
    try await until("the owning worker delivers deletion", timeout: .seconds(4)) {
      owner.worker.cell(MachineCell.ID(machine.rawValue)).presence.state == "deleted"
    }
    #expect(!owner.worker.hasMail(for: MachineCell.ID(machine.rawValue).recipient))
    try await other.close()
    try await owner.close()
  }
}

private final class HeldBoxAttachmentScheduler: Scheduler {
  private struct State {
    var pending = 0
    var holdNext = false
    var held: [UnownedJob] = []
    var waiters: [AsyncStream<Void>.Continuation] = []
  }

  let now: Instant
  private let queue = DispatchQueue(label: "held-box-attachment")
  private let state = Mutex(State())

  init() {
    @Dependency(\.date) var date
    now = Instant(milliseconds: Int64(date.now.timeIntervalSince1970 * 1000))
  }

  func schedule(_ lane: Lane) {
    submit { if lane.run(limit: 32, pick: { _ in 0 }) { self.schedule(lane) } }
  }

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    let held = state.withLock { state in
      guard state.holdNext else { return false }
      state.holdNext = false
      state.held.append(job)
      return true
    }
    if !held { submit { job.runSynchronously(on: self.asUnownedTaskExecutor()) } }
  }

  func holdNextTask() {
    state.withLock { state in
      precondition(!state.holdNext && state.held.isEmpty)
      state.holdNext = true
    }
  }

  var heldTaskCount: Int { state.withLock { $0.held.count } }

  func releaseHeldTasks() {
    let jobs = state.withLock { state in
      defer { state.held.removeAll() }
      return state.held
    }
    for job in jobs { submit { job.runSynchronously(on: self.asUnownedTaskExecutor()) } }
  }

  func post(_ event: @escaping @Sendable () -> Void) { submit(event) }
  func at(_: Instant, _: @escaping @Sendable () -> Void) {}

  private func submit(_ work: @escaping @Sendable () -> Void) {
    state.withLock { $0.pending += 1 }
    queue.async {
      work()
      let finished = self.state.withLock { state -> [AsyncStream<Void>.Continuation] in
        state.pending -= 1
        guard state.pending == 0 else { return [] }
        defer { state.waiters.removeAll() }
        return state.waiters
      }
      for waiter in finished { waiter.finish() }
    }
  }

  func drain() async {
    let done = AsyncStream<Void>.makeStream()
    let idle = state.withLock { state in
      guard state.pending > 0 else { return true }
      state.waiters.append(done.continuation)
      return false
    }
    if idle { done.continuation.finish() }
    for await _ in done.stream {}
  }
}
