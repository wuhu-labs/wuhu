#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import CExecSupervisor
@testable import ComputerFiles
@testable import ExecSupervisor
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Fetch
import enum JSONValue.JSONValue
import NIOPosix
import struct OperationProtocol.ErrorEnvelope
import struct OperationProtocol.OperationError
import struct OperationProtocol.OperationSnapshot
import struct OperationProtocol.StartRequest
import struct OperationRuntime.AnyOperationKind
import class OperationRuntime.OperationAgent
import typealias Serve.Handler
import Synchronization
import Testing

/// A private machine directory short enough for any platform's Unix socket limit: `/tmp/w252-XXXXXX/operations`.
struct MachineHome {
  let path: String
  var operations: String { path + "/operations" }
  var rendezvous: String { path + "/ctl.sock" }
  var workers: String { path + "/workers" }

  init(padding: Int = 0) throws {
    var template = Array("/tmp/w252-XXXXXX".utf8CString)
    guard let made = mkdtemp(&template) else { throw OperationError(.invalidConfiguration) }
    var path = String(cString: made)
    if padding > 0 {
      path += "/" + String(repeating: "m", count: padding)
      guard mkdir(path, 0o700) == 0 else { throw OperationError(.invalidConfiguration) }
    }
    self.path = path
    guard mkdir(operations, 0o700) == 0 else { throw OperationError(.invalidConfiguration) }
  }

  func remove() {
    let top = String(path.prefix("/tmp/w252-XXXXXX".utf8.count))
    try? FileManager.default.removeItem(atPath: top)
  }

  /// A supervisor's directory as an older agent wrote it.
  func manifest(_ id: UUID = UUID(), version: Int = 2) async throws -> SupervisorManifest {
    let directory = operations + "/" + id.uuidString
    let manifest = SupervisorManifest(version: version, machine: "test", operation: id, nonce: UUID().uuidString + UUID().uuidString, socket: version == 2 ? rendezvous : directory + "/control.sock")
    guard mkdir(directory, 0o700) == 0 else { throw OperationError(.invalidConfiguration) }
    try WorkerDirectory.writeFile(directory + "/manifest.json", JSONEncoder().encode(manifest))
    return manifest
  }

  func entries(_ id: UUID) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: operations + "/" + id.uuidString).sorted() }

  /// The worker directories whose worker still holds its lock.
  func liveWorkers() -> Set<UUID> {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: workers)) ?? []
    return Set(names.compactMap { name -> UUID? in
      guard let id = UUID(uuidString: name), access(workers + "/" + name + "/.lock", F_OK) == 0 else { return nil }
      guard let fd = WorkerDirectory.lock(workers + "/" + name, create: false) else { return id }
      exec_close(fd)
      return nil
    })
  }
}

/// The supervisor half of an older agent's production, in process: the operation agent behind the nonce gate, redialing `ctl.sock`.
func withSupervisor<R: Sendable>(_ manifest: SupervisorManifest, _ body: @Sendable () async throws -> R) async throws -> R {
  let agent = try OperationAgent(machine: manifest.machine, kinds: [AnyOperationKind(ExecKind())], authorize: { request, _ in
    guard request.headers["X-Wuhu-Supervisor-Nonce"] == manifest.nonce else { throw OperationError(.machineNotAuthorized) }
  })
  let gate = SupervisorGate(manifest: manifest, agent: agent)
  let events = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let hello = Rendezvous.Hello(protocol: Rendezvous.protocolName, machine: manifest.machine, operation: manifest.operation, nonce: manifest.nonce)
  let result: Result<R, any Error> = await withTaskGroup(of: Void.self) { group in
    group.addTask { await agent.run() }
    group.addTask { _ = await Rendezvous.redial(path: manifest.socket, hello: { hello }, group: events, handler: gate.handler) }
    let result: Result<R, any Error>
    do { result = .success(try await body()) } catch { result = .failure(error) }
    await agent.shutdown(); group.cancelAll()
    return result
  }
  try await events.shutdownGracefully()
  return try result.get()
}

func waitForLink(_ workers: ExecWorkers, _ id: UUID) async throws {
  let clock = ContinuousClock(); let deadline = clock.now + .seconds(5)
  while await workers.supervisors[id]?.link == nil {
    guard clock.now < deadline else { throw TestFailure.timeout }
    try await clock.sleep(for: .milliseconds(10))
  }
}

/// Exec workers run as tasks of this process: the agent's launch starts one, and `finish` waits for every one to end.
final class InProcessWorkers: Sendable {
  let tasks = Mutex<[Task<Void, Never>]>([])

  var launch: @Sendable ([String]) async throws -> Int32? {
    { arguments in
      let directory = arguments[3]
      let task = Task { _ = try? await ExecSupervisor.runWorker(directory: directory) }
      self.tasks.withLock { $0.append(task) }
      return nil
    }
  }

  /// The workers end with the composition: one that holds nothing exits once its agent is gone. Only one that outlives the
  /// fallback is cancelled, which can cut a redial short.
  func finish() async {
    let tasks = tasks.withLock { $0 }
    await withTaskGroup(of: Void.self) { group in
      group.addTask { for task in tasks { await task.value } }
      group.addTask {
        do { try await ContinuousClock().sleep(for: .seconds(15)) } catch { return }
        for task in tasks { task.cancel() }
      }
      await group.next()
      group.cancelAll()
    }
    for task in tasks { await task.value }
  }
}

/// The agent with its exec workers in this process. Its workers end with it; adopted supervisors keep running.
func compose<R: Sendable>(_ home: MachineHome, _ body: @escaping @Sendable (ComputerAgent, ExecWorkers) async throws -> R) async throws -> R {
  let inProcess = InProcessWorkers()
  let result: Result<R, any Error>
  do {
    result = .success(try await ExecSupervisor.composeComputerAgent(machine: "test", operationsDirectory: home.operations, executable: "/bin/false", files: .local, kinds: [], launch: inProcess.launch) { agent, workers in
      let outcome: Result<R, any Error>
      do { outcome = .success(try await body(agent, workers)) } catch { outcome = .failure(error) }
      return try outcome.get()
    })
  } catch { result = .failure(error) }
  await inProcess.finish()
  return try result.get()
}

@Suite struct RendezvousTests {
  @Test func supervisorKeepsRunningAndReattachesThroughCtlSockAfterAgentRestart() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let manifest = try await home.manifest()
    let id = manifest.operation
    try await withSupervisor(manifest) {
      // First agent: the supervisor dials it, and the command starts over the link.
      try await compose(home) { _, workers in
        try await waitForLink(workers, id)
        let start = execRequest(id, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh", "-c", "printf before; sleep 1; printf after; exit 3"], "cwd": "/tmp", "stdin": false])))
        #expect(try await workers.forward(start, manifest.operation, to: .supervisor).status.code == 201)
      }
      var state = stat()
      #expect(lstat(home.rendezvous, &state) != 0, "the departing agent removes its ctl.sock")
      // Agent down while the command runs; the second agent recovers the manifest and the supervisor redials it.
      try await ContinuousClock().sleep(for: .milliseconds(300))
      try await compose(home) { computer, _ in
        let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
        var output = Data(); var after = 0; var ended = false
        while !ended {
          guard clock.now < deadline else { throw TestFailure.timeout }
          let snapshot = try await computer.handler(execRequest(id, query: "?channel=stdout&after=\(after)")).body.json(OperationSnapshot.self)
          output += snapshot.payload?.data ?? Data(); after = Int(snapshot.through?.rawValue ?? UInt64(after))
          ended = snapshot.channelEnd
          if !ended { try await clock.sleep(for: .milliseconds(20)) }
        }
        #expect(String(decoding: output, as: UTF8.self) == "beforeafter")
        var verdict: OperationSnapshot?
        while verdict?.verdict == nil {
          guard clock.now < deadline else { throw TestFailure.timeout }
          verdict = try await computer.handler(execRequest(id)).body.json(OperationSnapshot.self)
          if verdict?.verdict == nil { try await clock.sleep(for: .milliseconds(20)) }
        }
        #expect(verdict?.verdict?.result == ["termination": ["tag": "exit", "code": 3]])
        #expect(try home.entries(id) == ["manifest.json"], "no per-operation socket file")
      }
    }
  }

  @Test func theSupervisorProcessExitsOnceItsOperationSettlesEvenAcrossAnAgentRestart() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let manifest = try await home.manifest()
    let id = manifest.operation
    let directory = home.operations + "/" + id.uuidString
    let supervisor = Task { try await ExecSupervisor.run(directory: directory) }
    defer { supervisor.cancel() }
    try await compose(home) { _, workers in
      try await waitForLink(workers, id)
      let start = execRequest(id, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh", "-c", "printf done"], "cwd": "/tmp", "stdin": false])))
      #expect(try await workers.forward(start, manifest.operation, to: .supervisor).status.code == 201)
    }
    try await compose(home) { computer, workers in
      try await waitForLink(workers, id)
      let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
      var finals: [String: UInt64] = [:]
      for channel in ["stdout", "stderr"] {
        var after: UInt64 = 0
        defer { finals[channel] = after }
        while true {
          guard clock.now < deadline else { throw TestFailure.timeout }
          let snapshot = try await computer.handler(execRequest(id, query: "?channel=\(channel)&after=\(after)")).body.json(OperationSnapshot.self)
          let through = snapshot.through?.rawValue ?? after
          if snapshot.channelEnd, through == after { break }
          if through == after { try await clock.sleep(for: .milliseconds(20)) }
          after = through
        }
      }
      var token: UUID?
      while token == nil {
        guard clock.now < deadline else { throw TestFailure.timeout }
        token = try await computer.handler(execRequest(id)).body.json(OperationSnapshot.self).terminalToken
        if token == nil { try await clock.sleep(for: .milliseconds(20)) }
      }
      // The server acks on each channel's poll in turn; stderr is empty, and its ack must still find the operation.
      for channel in ["stdout", "stderr"] {
        #expect(FileManager.default.fileExists(atPath: directory))
        #expect(try await computer.handler(execRequest(id, query: "?channel=\(channel)&after=\(finals[channel]!)&terminalAck=\(token!.uuidString)")).status.code == 200)
      }
      while FileManager.default.fileExists(atPath: directory) {
        guard clock.now < deadline else { throw TestFailure.timeout }
        try await clock.sleep(for: .milliseconds(50))
      }
    }
    try await supervisor.value
  }

  @Test func handshakeRefusesAWrongNonceAnUnknownOperationAndAnUnknownWorkerOverTheRealSocket() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let manifest = try await home.manifest()
    let events = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    try await compose(home) { _, workers in
      let handler: @Sendable (Request) async throws -> Response = { _ in Issue.record("a refused supervisor was asked to serve"); return try .json(true) }
      var hello = Rendezvous.Hello(protocol: Rendezvous.protocolName, machine: "test", operation: manifest.operation, nonce: UUID().uuidString + UUID().uuidString)
      do { _ = try await Rendezvous.dial(path: home.rendezvous, hello: hello, group: events, handler: handler); Issue.record("wrong nonce admitted") }
      catch { #expect(error as? Rendezvous.Refusal == .nonceMismatch) }
      hello.operation = UUID(); hello.nonce = manifest.nonce
      do { _ = try await Rendezvous.dial(path: home.rendezvous, hello: hello, group: events, handler: handler); Issue.record("unknown operation admitted") }
      catch { #expect(error as? Rendezvous.Refusal == .unknownOperation) }
      #expect(await workers.supervisors[manifest.operation]?.link == nil)
      let worker = Rendezvous.Hello(protocol: Rendezvous.protocolName, machine: "test", worker: UUID(), nonce: manifest.nonce)
      do { _ = try await Rendezvous.dial(path: home.rendezvous, hello: worker, group: events, handler: handler); Issue.record("unknown worker admitted") }
      catch { #expect(error as? Rendezvous.Refusal == .unknownWorker) }
      // A refusal is final: the dialer gets it back instead of redialing.
      let refused = await Rendezvous.redial(path: home.rendezvous, hello: { worker }, group: events, handler: handler)
      #expect(refused == .unknownWorker)
    }
    try await events.shutdownGracefully()
  }

  @Test func overlongRendezvousPathRefusesToStartAndNamesThePath() async throws {
    // "/tmp/w252-XXXXXX/" + padding + "/ctl.sock" one byte over the platform's sun_path limit; a Mac username of 58+ bytes does the same.
    let limit = Rendezvous.maximumSocketPathBytes
    let home = try MachineHome(padding: limit + 1 - 17 - 9); defer { home.remove() }
    #expect(home.rendezvous.utf8.count == limit + 1)
    do {
      _ = try await compose(home) { _, _ in Issue.record("agent started with an unbindable rendezvous socket") }
      Issue.record("no typed refusal")
    } catch let error as OperationError {
      #expect(error.code == .invalidConfiguration)
      #expect(error.message.contains(home.rendezvous))
      #expect(error.details == ["path": .string(home.rendezvous), "bytes": .number(Double(limit + 1)), "maximumBytes": .number(Double(limit))])
    }
    var state = stat()
    #expect(lstat(home.operations + "/.agent.lock", &state) != 0, "the refusal comes before the machine lock is taken")
  }

  @Test func rendezvousPathAtThePlatformLimitBindsAndAdmitsASupervisor() async throws {
    let limit = Rendezvous.maximumSocketPathBytes
    let home = try MachineHome(padding: limit - 17 - 9); defer { home.remove() }
    #expect(home.rendezvous.utf8.count == limit)
    let manifest = try await home.manifest()
    try await withSupervisor(manifest) {
      try await compose(home) { _, workers in
        var state = stat()
        #expect(lstat(home.rendezvous, &state) == 0 && state.st_mode & S_IFMT == S_IFSOCK && state.st_mode & 0o777 == 0o600)
        try await waitForLink(workers, manifest.operation)
      }
    }
  }

  /// A version-1 supervisor listens on its own socket, and this agent does not adopt it: its operation answers a typed unknown
  /// outcome and counts as lost at departure, the live supervisor is asked to retire, and a dead one's directory goes.
  @Test func aVersionOneSupervisorsOperationHasAnUnknownOutcomeAndItIsRetired() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let alive = try await home.manifest(version: 1)
    let dead = try await home.manifest(version: 1)
    let listener = try unixListener(alive.socket)
    defer { _ = close(listener) }
    let request = Task { try await acceptOneRequest(listener) }
    try await compose(home) { computer, workers in
      #expect(await workers.supervisors.isEmpty)
      #expect(try await workers.external.usage() == ExternalUsage())
      for query in ["", "?channel=stdout&after=0"] {
        let error = try await computer.handler(execRequest(alive.operation, query: query)).body.json(ErrorEnvelope.self).error
        #expect(error.code == .unknownOperation && error.operation == alive.operation)
        #expect(error.details == ["outcome": "unknown", "reason": "supervisorNotAdopted"])
      }
      // Its id stays taken.
      let start = execRequest(alive.operation, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false])))
      #expect(try await computer.handler(start).body.json(ErrorEnvelope.self).error.code == .operationExists)
      await workers.leave()
      let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
      while true {
        switch try await workers.departureEvidence() {
        case .pending:
          guard clock.now < deadline else { throw TestFailure.timeout }
          try await clock.sleep(for: .milliseconds(20))
          continue
        case let .leaseExpired(lost): #expect(Set(lost) == [alive.operation, dead.operation])
        case .drained: Issue.record("the unadopted operations drained")
        }
        break
      }
    }
    let text = try await request.value
    #expect(text.hasPrefix("PUT /retire HTTP/1.1\r\n"))
    #expect(text.contains("X-Wuhu-Supervisor-Nonce: \(alive.nonce)\r\n"))
    #expect(try home.entries(alive.operation) == ["control.sock", "manifest.json"])
    #expect(access(home.operations + "/" + dead.operation.uuidString, F_OK) != 0)
  }
}

/// A listening Unix socket at `path`, as a version-1 supervisor keeps.
func unixListener(_ path: String) throws -> Int32 {
  #if os(Linux)
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
  #else
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  #endif
  guard fd >= 0 else { throw OperationError(.invalidConfiguration) }
  var address = sockaddr_un()
  address.sun_family = sa_family_t(AF_UNIX)
  withUnsafeMutableBytes(of: &address.sun_path) { buffer in
    for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
  }
  let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
  guard bound == 0, listen(fd, 4) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { _ = close(fd); throw OperationError(.invalidConfiguration) }
  return fd
}

/// Accepts one connection on `listener`, reads its request head, answers 200 and returns the head.
func acceptOneRequest(_ listener: Int32) async throws -> String {
  let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
  var connection: Int32 = -1
  while connection < 0 {
    connection = accept(listener, nil, nil)
    if connection < 0 {
      guard clock.now < deadline else { throw TestFailure.timeout }
      try await clock.sleep(for: .milliseconds(10))
    }
  }
  defer { _ = close(connection) }
  var head: [UInt8] = []
  var buffer = [UInt8](repeating: 0, count: 1024)
  while !String(decoding: head, as: UTF8.self).contains("\r\n\r\n") {
    let count = read(connection, &buffer, buffer.count)
    guard count > 0 else { break }
    head += buffer[0 ..< count]
  }
  let reply = Array("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\ntrue".utf8)
  _ = write(connection, reply, reply.count)
  return String(decoding: head, as: UTF8.self)
}
