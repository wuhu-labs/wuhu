import Assertion
import Crypto
import Dependencies
import DeterministicDependencies
import Dispatch
import Fetch
import FetchTunnel
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
  func credentialResetClosesTheOwningBox(action: String) async throws {
    let space = try Space.inMemory()
    let key = Curve25519.Signing.PrivateKey()
    let enrolled = try await space.enrollMachineV2(name: "box", group: .shared, pubkey: key.pubkeyLabel)
    let machine = enrolled.machine.id
    let id = MachineCell.ID(machine.rawValue)
    let closed = Gate()
    let closes = Mutex(0)
    let socket = try #require(space.worker.attach(BoxSocket.self, to: id, opening: .init(connection: UUID(), pubkey: key.pubkeyLabel, streams: 32)) {
      switch $0 {
      case .frame: break
      case .closed: closes.withLock { $0 += 1 }; closed.open()
      }
    })
    defer { socket.close() }
    let hub = MachineHub(space: space)
    let devPerson = try await space.ensureDevPerson()
    let handler = SpaceServer.configuredHandler(space: space, hub: hub, devPerson: devPerson, listenerRoutes: machineListenerRoutes(space: space, hub: hub, devPerson: devPerson))
    let request: Request
    if action == "selfRevoke" {
      request = try await MachineV2TunnelTests().signed(handler, "/v1/machine-v2/\(machine.rawValue)/revoke", key: key, machine: machine)
    } else {
      request = Request(url: URL(string: "https://space.test/v1/machine/\(machine.rawValue)/\(action)")!, method: .post)
    }
    guard case let .response(response) = try await handler(request) else { Issue.record("control must be HTTP"); return }
    #expect(response.status == .ok)
    #expect(try await space.machine(pubkey: key.pubkeyLabel) == nil)
    space.worker.start()
    try await until("the revoked box closes", timeout: .seconds(4)) { closed.isOpen }
    do {
      try await MachineHub(space: space).authorize(.init(pubkey: key.pubkeyLabel, machines: [machine.rawValue]))
      Issue.record("redial with the purged key was authorized")
    } catch let error as OperationError { #expect(error.code == .machineNotAuthorized) }
    try await until("the close mail is consumed", timeout: .seconds(4)) { !space.worker.hasMail(for: id.recipient) }
    #expect(closes.withLock { $0 } == 1)
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
        let handler = SpaceServer.configuredHandler(space: space, hub: hub, devPerson: try await space.ensureDevPerson())
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
    await space.stopWorker()
    let database = space.database
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
      let handler = SpaceServer.configuredHandler(space: space, hub: hub, devPerson: try await space.ensureDevPerson())
      let request = Request(url: URL(string: "https://space.test/v1/machine/\(machine.id.rawValue)/revoke")!, method: .post)
      guard case let .response(response) = try await handler(request) else { Issue.record("Revoke must be HTTP"); return }
      #expect(response.status == .ok)
      #expect(try await space.machine(pubkey: key.pubkeyLabel) == nil)
      #expect(worker.hasMail(for: id.recipient))
      worker.poke(id.recipient)
      await scheduler.drain()
      let recipient = id.description
      let mail = try RawDatabase.open(space.databasePath) {
        try $0.int("SELECT COUNT(*) FROM wuwei_mail WHERE recipient = ?", arguments: [recipient])!
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
    try await space.close()
  }

  @Test func killOnNonhostingWorkerIsAcceptedAndDeliveredAsMail() async throws {
    let folder = try ScratchFolder("machine-cross-worker-kill")
    defer { folder.remove() }
    let file = folder.url.appendingPathComponent("space.sqlite")
    let owner = try Space.open(file: file)
    let machine = try await owner.addMachineV2(name: "box").machine.id
    let exec = try await owner.reserveExec(machine: machine)
    let account = try await owner.addAccount(kind: .human, name: "operator", admin: true)
    let key = Curve25519.Signing.PrivateKey()
    let credential = try await owner.addKey(key.pubkeyLabel, account: account.id, capabilities: [.device], createdBy: nil, expiresAt: nil)
    _ = try await owner.adoptPersona(key: credential)
    let identity = try await owner.identity().rawValue
    let assertion = try AssertionClaims(key: key.pubkeyLabel, space: identity, expiresAt: Date().addingTimeInterval(3600)).signed(by: key)
    let other = try Space.open(file: file)
    let server = try await TestServer(space: other, clock: ContinuousClock(), dev: false)
    var request = Request(url: URL(string: "http://space/v1/exec/\(exec.id.rawValue)/kill")!, method: .post)
    request.headers[.authorization] = "Bearer " + assertion.rawValue
    let response = try await server.api(request)
    #expect(response.status == .ok)
    owner.worker.start()
    try await until("the owning worker applies stop mail", timeout: .seconds(4)) {
      try await owner.execRecord(exec.id)?.terminal != nil
    }
    #expect(try await owner.execRecord(exec.id)?.terminal == .cancelled)
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
