#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
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
import class ServeNIO.ServeNIOServer
import Synchronization
import Testing

/// A private machine directory short enough for any platform's Unix socket limit: `/tmp/w252-XXXXXX/operations`.
struct MachineHome {
  let path: String
  var operations: String { path + "/operations" }
  var rendezvous: String { path + "/ctl.sock" }

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

  func manifest(_ id: UUID = UUID(), version: Int = 2) async throws -> SupervisorManifest {
    let directory = operations + "/" + id.uuidString
    let manifest = SupervisorManifest(version: version, machine: "test", operation: id, nonce: UUID().uuidString + UUID().uuidString, socket: version == 2 ? rendezvous : directory + "/control.sock")
    try await SupervisorFiles.live.create(directory, manifest)
    return manifest
  }

  func entries(_ id: UUID) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: operations + "/" + id.uuidString).sorted() }
}

/// The supervisor half of production, in process: the operation agent behind the nonce gate, redialing `ctl.sock`.
/// `starts` sees each start request as it arrives over the link, before the supervisor handles it.
func withSupervisor<R: Sendable>(_ manifest: SupervisorManifest, starts: (@Sendable (StartRequest) -> Void)? = nil, _ body: @Sendable () async throws -> R) async throws -> R {
  let agent = try OperationAgent(machine: manifest.machine, kinds: [AnyOperationKind(ExecKind())], authorize: { request, _ in
    guard request.headers["X-Wuhu-Supervisor-Nonce"] == manifest.nonce else { throw OperationError(.machineNotAuthorized) }
  })
  let gate = SupervisorGate(manifest: manifest, agent: agent)
  let handler: Handler = { request in
    guard let starts, request.method == .post, let body = request.body else { return try await gate.handler(request) }
    let bytes = try await body.bytes(upTo: 1 << 20)
    if let start = try? JSONDecoder().decode(StartRequest.self, from: bytes) { starts(start) }
    var replay = request; replay.body = .bytes(bytes, contentType: body.contentType)
    return try await gate.handler(replay)
  }
  let events = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  let hello = Rendezvous.Hello(protocol: Rendezvous.protocolName, machine: manifest.machine, operation: manifest.operation, nonce: manifest.nonce)
  let result: Result<R, any Error> = await withTaskGroup(of: Void.self) { group in
    group.addTask { await agent.run() }
    group.addTask { await Rendezvous.redial(path: manifest.socket, hello: hello, group: events, handler: handler) }
    let result: Result<R, any Error>
    do { result = .success(try await body()) } catch { result = .failure(error) }
    await agent.shutdown(); group.cancelAll()
    return result
  }
  try await events.shutdownGracefully()
  return try result.get()
}

func waitForLink(_ registry: ExecSupervisorRegistry, _ id: UUID) async throws {
  let clock = ContinuousClock(); let deadline = clock.now + .seconds(5)
  while await registry.links[id] == nil {
    guard clock.now < deadline else { throw TestFailure.timeout }
    try await clock.sleep(for: .milliseconds(10))
  }
}

func compose<R: Sendable>(_ home: MachineHome, _ body: @escaping @Sendable (ComputerAgent, ExecSupervisorRegistry) async throws -> R) async throws -> R {
  try await ExecSupervisor.composeComputerAgent(machine: "test", operationsDirectory: home.operations, executable: "/bin/false", files: .local, kinds: [], body)
}

@Suite struct RendezvousTests {
  @Test func supervisorKeepsRunningAndReattachesThroughCtlSockAfterAgentRestart() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let manifest = try await home.manifest()
    let id = manifest.operation
    try await withSupervisor(manifest) {
      // First agent: the supervisor dials it, and the command starts over the link.
      try await compose(home) { _, registry in
        try await waitForLink(registry, id)
        let start = execRequest(id, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh", "-c", "printf before; sleep 1; printf after; exit 3"], "cwd": "/tmp", "stdin": false])))
        #expect(try await registry.send(start, to: manifest, identity: false).status.code == 201)
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
    try await compose(home) { _, registry in
      try await waitForLink(registry, id)
      let start = execRequest(id, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh", "-c", "printf done"], "cwd": "/tmp", "stdin": false])))
      #expect(try await registry.send(start, to: manifest, identity: false).status.code == 201)
    }
    try await compose(home) { computer, registry in
      try await waitForLink(registry, id)
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

  // The ctl.sock link replaced the per-operation socket as transport only: a start's server attribution reaches the supervisor intact.
  @Test func aStartsCallerCrossesTheCtlSockLinkToTheSupervisor() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let manifest = try await home.manifest()
    let caller = StartRequest.Caller(session: "quick-breeze-badge", title: "Backend coder", group: "shared")
    let seen = Mutex<[StartRequest.Caller?]>([])
    try await withSupervisor(manifest, starts: { start in seen.withLock { $0.append(start.caller) } }) {
      try await compose(home) { _, registry in
        try await waitForLink(registry, manifest.operation)
        let start = execRequest(manifest.operation, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/true"], "cwd": "/tmp", "stdin": false], caller: caller)))
        #expect(try await registry.send(start, to: manifest, identity: false).status.code == 201)
      }
    }
    #expect(seen.withLock { $0 } == [caller])
  }

  @Test func handshakeRefusesAWrongNonceAndAnUnknownOperationOverTheRealSocket() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let manifest = try await home.manifest()
    let events = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    try await compose(home) { _, registry in
      let handler: @Sendable (Request) async throws -> Response = { _ in Issue.record("a refused supervisor was asked to serve"); return try .json(true) }
      var hello = Rendezvous.Hello(protocol: Rendezvous.protocolName, machine: "test", operation: manifest.operation, nonce: UUID().uuidString + UUID().uuidString)
      do { _ = try await Rendezvous.dial(path: home.rendezvous, hello: hello, group: events, handler: handler); Issue.record("wrong nonce admitted") }
      catch { #expect(error as? Rendezvous.Refusal == .nonceMismatch) }
      hello.operation = UUID(); hello.nonce = manifest.nonce
      do { _ = try await Rendezvous.dial(path: home.rendezvous, hello: hello, group: events, handler: handler); Issue.record("unknown operation admitted") }
      catch { #expect(error as? Rendezvous.Refusal == .unknownOperation) }
      #expect(await registry.links.isEmpty)
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
      try await compose(home) { _, registry in
        var state = stat()
        #expect(lstat(home.rendezvous, &state) == 0 && state.st_mode & S_IFMT == S_IFSOCK && state.st_mode & 0o777 == 0o600)
        try await waitForLink(registry, manifest.operation)
        let identity = try await registry.send(Request(url: URL(string: "http://supervisor/identity")!), to: manifest, identity: true)
        #expect(try await identity.body.json(SupervisorManifest.self) == manifest)
      }
    }
  }

  @Test func newAgentReattachesALegacyPerOperationSocketSupervisor() async throws {
    let home = try MachineHome(); defer { home.remove() }
    let manifest = try await home.manifest(version: 1)
    let agent = try OperationAgent(machine: "test", kinds: [AnyOperationKind(ExecKind())], authorize: { request, _ in
      guard request.headers["X-Wuhu-Supervisor-Nonce"] == manifest.nonce else { throw OperationError(.machineNotAuthorized) }
    })
    let gate = SupervisorGate(manifest: manifest, agent: agent)
    let server = try await ServeNIOServer.bind(unixDomainSocketPath: manifest.socket, handler: gate.handler)
    let runner = Task { await agent.run() }
    defer { runner.cancel() }
    var start = execRequest(manifest.operation, method: .post, body: try .json(StartRequest(kind: "exec.v1", input: ["argv": ["/bin/sh", "-c", "printf legacy"], "cwd": "/tmp", "stdin": false])))
    start.headers["X-Wuhu-Supervisor-Nonce"] = manifest.nonce
    #expect(try await gate.handler(start).status.code == 201)
    try await compose(home) { computer, registry in
      let clock = ContinuousClock(); let deadline = clock.now + .seconds(10)
      var snapshot = try await computer.handler(execRequest(manifest.operation)).body.json(OperationSnapshot.self)
      while snapshot.verdict == nil {
        guard clock.now < deadline else { throw TestFailure.timeout }
        try await clock.sleep(for: .milliseconds(20))
        snapshot = try await computer.handler(execRequest(manifest.operation)).body.json(OperationSnapshot.self)
      }
      #expect(snapshot.verdict?.result == ["termination": ["tag": "exit", "code": 0]])
      #expect(await registry.links.isEmpty, "a version-1 supervisor is reached on its own socket")
    }
    await agent.shutdown(); await server.shutdown()
  }
}
