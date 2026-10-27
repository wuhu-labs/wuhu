import Clocks
import ControlledTime
import struct Credentials.CredentialResolver
import struct Credentials.SpaceSecretStores
import Dependencies
import Fetch
import FileSearch
import Foundation
import JSONValue
import struct LoopCore.SessionExecution
import MachineChannel
import struct MachineContract.Ack
import struct MachineContract.Base64Data
import struct MachineContract.ExecExit
import struct MachineContract.ExecID
import struct MachineContract.ExecMintInput
import struct MachineContract.ExecMintOutput
import struct MachineContract.MachineEntry
import struct MachineContract.MachineError
import struct MachineContract.MachineID
import enum MachineContract.VFSDefaults
import enum MachineContract.VFSOp
import enum MachineContract.VFSResult
import class MainHub.Hub
import protocol MainHub.Worker
import Serve
import SessionDomain
@testable import SessionTools
import struct SpaceClient.SpaceClient
import struct SpaceContract.GroupID
import SpaceCore
@testable import SpaceServer
import SpaceTools
import Synchronization
import Testing
import struct WuhuAI.ToolArguments
import struct WuhuAI.ToolCall

let anchor = Date(timeIntervalSinceReferenceDate: 0)

struct SeededRNG: RandomNumberGenerator {
  private var state: UInt64
  init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

final class Box<Value: Sendable>: Sendable {
  private let mutex: Mutex<Value>
  init(_ value: Value) { mutex = .init(value) }
  var value: Value { mutex.withLock { $0 } }
  func withLock<R: Sendable>(_ body: (inout sending Value) -> sending R) -> R { mutex.withLock(body) }
}

func withToolDeps<R>(
  seed: UInt64 = 7,
  _ body: (TimeControl) async throws -> R,
) async throws -> R {
  try await withDependencies {
    $0.installTimeControl(anchor: anchor)
    $0.uuid = .incrementing
    $0.withRandomNumberGenerator = .init(SeededRNG(seed: seed))
  } operation: {
    @Dependency(\.timeControl) var timeControl
    return try await body(timeControl)
  }
}

struct TimeoutError: Error {}

// Real-clock polling on purpose: subscription database work happens off the
// cooperative pool, so a TestClock advance can complete while delivery is still
// in flight — assertions must wait for the effect, not for quiescence.
func until(
  _ description: String,
  timeout: Duration = .seconds(10),
  _ condition: () async throws -> Bool,
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if try await condition() { return }
    try? await clock.sleep(for: .milliseconds(2))
  }
  Issue.record("timed out waiting for \(description)")
  throw TimeoutError()
}

// A subscription task can install its TestClock sleep after a bulk advance.
// Nudging the clock per attempt un-parks that late sleep; the small step bounds
// the over-advance so exact fire counts stay assertable.
func untilAdvancing(
  _ description: String,
  _ time: TimeControl,
  stepSeconds: Double = 1,
  attempts: Int = 600,
  _ condition: () async throws -> Bool,
) async throws {
  let clock = ContinuousClock()
  for _ in 0 ..< attempts {
    if try await condition() { return }
    await time.advance(by: stepSeconds)
    try? await clock.sleep(for: .milliseconds(2))
  }
  Issue.record("timed out waiting for \(description)")
  throw TimeoutError()
}

func holds(
  _ description: String,
  for window: Duration = .milliseconds(100),
  _ condition: () async throws -> Bool,
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: window)
  while clock.now < deadline {
    if !(try await condition()) {
      Issue.record("expected \(description) to hold, but it broke")
      return
    }
    try? await clock.sleep(for: .milliseconds(2))
  }
}

extension TimeControl {
  // The microsecond of slack absorbs Double<->Duration rounding: a scheduled
  // sleep must fire when we advance by its nominal delay.
  func advance(by seconds: Double) async {
    @Dependency(\.date) var date
    await advance(to: date.now.addingTimeInterval(seconds + 1e-6))
  }
}

func makeSession(_ space: Space, name: String = "test", group: GroupID = .shared) async throws -> SessionID {
  let id = try await space.sessions.createSession(
    group: group,
    title: name,
    kind: .agent,
    createdBy: "morgan",
    model: .init(provider: "deepseek", model: "deepseek-v4-pro", effort: "high"),
  )
  return id
}

// The kernel's side of the black box: dispatch a call with the folded state,
// then fold the committed result exactly as the transcript would.
struct ToolWorld {
  private let execute: @Sendable (SessionID, ToolCall, ToolExecutionState) async throws -> ToolOutcome
  let session: SessionID
  var state = ToolExecutionState()
  var delivered: ScopeContext?
  private var mintedCalls = 0
  // A kernel never reuses a tool call id within a session, and main answers a
  // repeated id with its first result: implicit ids are unique per world, and
  // a retry names its call explicitly.
  private let minting = String(UUID().uuidString.lowercased().prefix(8))

  init(executor: ToolExecutor, session: SessionID) {
    execute = { try await executor.execute(session: $0, call: $1, state: $2) }
    self.session = session
  }

  init(worker: SessionExecution, session: SessionID) {
    execute = { try await worker.execute(session: $0, call: $1, state: $2) }
    self.session = session
  }

  init(_ world: ToolWorld, session: SessionID) {
    execute = world.execute
    self.session = session
  }

  mutating func run(
    _ name: String,
    _ arguments: ToolArguments,
    id explicit: String? = nil,
  ) async throws -> ToolResultPayload {
    mintedCalls += 1
    let id = explicit ?? "tc-\(minting)-\(mintedCalls)"
    let outcome = try await execute(
      session, ToolCall(id: id, name: name, arguments: arguments),
      state,
    )
    state.apply(outcome.payload)
    await outcome.committed?()
    delivered = outcome.context
    if let delivered {
      state.apply(delivered: .notification(delivered.notice(id: UUID(), at: Date(timeIntervalSince1970: 0))))
    }
    return outcome.payload
  }

  // A crash-retry: the kernel never committed the first result, so the retry
  // dispatches against the OLD state under the SAME kernel tool call id.
  func retry(
    _ name: String,
    _ arguments: ToolArguments,
    id: String,
  ) async throws -> ToolResultPayload {
    try await execute(
      session, ToolCall(id: id, name: name, arguments: arguments),
      state,
    ).payload
  }
}

func failure(_ payload: ToolResultPayload) throws -> ToolFailure {
  guard case let .failure(failure) = payload else {
    throw Mismatch("expected a failure, got \(payload)")
  }
  return failure
}

func failureMessage(_ payload: ToolResultPayload) throws -> String {
  guard case let .failure(failure) = payload else {
    throw Mismatch("expected a failure, got \(payload)")
  }
  return failure.message
}

struct Mismatch: Error {
  var message: String
  init(_ message: String) { self.message = message }
}

// MARK: - Fake machine filesystem behind the MachineSeam

final class FakeMachineFS: Sendable {
  struct File: Sendable {
    var mtime: Double
    var content: [UInt8]
  }

  let files = Box<[String: File]>([:])
  let ranges: Bool
  let opaqueTokens: Bool
  let writes = Box<[VFSOp]>([])
  let reads = Box<[VFSOp]>([])
  /// `MachineSeam.caller` as each vfs call saw it.
  let callers = Box<[SessionID?]>([])

  init(ranges: Bool = true, opaqueTokens: Bool = false) {
    self.ranges = ranges
    self.opaqueTokens = opaqueTokens
  }

  // A file here replaces the one at its path right after that path's next stat.
  let replacedAfterStat = Box<[String: File]>([:])
  let clockSeconds = Box<Double>(1000)
  let attached = Box<Set<MachineID>>([])
  let stats = Box<Int>(0)

  func put(_ path: String, _ content: String, mtime: Double) {
    files.withLock { $0[path] = File(mtime: mtime, content: Array(content.utf8)) }
  }

  func put(_ path: String, bytes: [UInt8], mtime: Double) {
    files.withLock { $0[path] = File(mtime: mtime, content: bytes) }
  }

  var seam: MachineSeam {
    let token: @Sendable (Double) -> String = { [opaqueTokens] in opaqueTokens ? "opaque:\($0)" : String($0) }
    return MachineSeam(
      vfs: { [files, clockSeconds, stats, ranges, reads, writes, replacedAfterStat, callers] _, op in
        callers.withLock { $0.append(MachineSeam.caller) }
        switch op {
        case let .read(path, offset, length):
          reads.withLock { $0.append(op) }
          guard let file = files.withLock({ $0[path] }) else {
            return .error(error: .init(code: .notFound, message: "not found: \(path)"))
          }
          guard ranges, offset != nil || length != nil else {
            guard file.content.count <= VFSDefaults.maxReadBytes else {
              return .error(error: .init(code: .tooLarge, message: "read of \(path) exceeds the wire bound"))
            }
            return .file(token: token(file.mtime), data: .init(file.content))
          }
          let start = min(offset ?? 0, file.content.count)
          let end = min(start + (length ?? file.content.count), file.content.count)
          return .file(token: token(file.mtime), data: .init(Array(file.content[start ..< end])))
        case let .stat(path):
          stats.withLock { $0 += 1 }
          let name = String(path.split(separator: "/").last ?? "")
          if let file = files.withLock({ $0[path] }) {
            if let next = replacedAfterStat.withLock({ $0.removeValue(forKey: path) }) {
              files.withLock { $0[path] = next }
            }
            return .entry(entry: .init(
              name: name,
              kind: .file,
              size: file.content.count,
              token: token(file.mtime),
              mtime: file.mtime,
            ))
          }
          guard files.withLock({ $0.keys.contains { $0.hasPrefix(path + "/") } }) else {
            return .error(error: .init(code: .notFound, message: "not found: \(path)"))
          }
          return .entry(entry: .init(name: name, kind: .directory, size: 0, token: "", mtime: 0))
        case let .write(path, data, ifMatch):
          writes.withLock { $0.append(op) }
          if let ifMatch, files.withLock({ $0[path].map { token($0.mtime) } }) != ifMatch {
            return .error(error: .init(code: .conflict, message: "stale token; re-read"))
          }
          let mtime = clockSeconds.withLock { seconds -> Double in
            seconds += 1
            return seconds
          }
          files.withLock { $0[path] = File(mtime: mtime, content: data.bytes) }
          return .written(token: token(mtime))
        case .mkdir:
          return .ok
        case let .ls(path):
          let prefix = path == "/" ? "/" : path + "/"
          let entries = files.withLock { all in
            var children: [String: MachineEntry] = [:]
            for (key, file) in all where key.hasPrefix(prefix) {
              let rest = key.dropFirst(prefix.count)
              let name = String(rest.prefix { $0 != "/" })
              children[name] = rest.contains("/")
                ? MachineEntry(name: name, kind: .directory, size: 0, token: "", mtime: 0)
                : MachineEntry(
                  name: name,
                  kind: .file,
                  size: file.content.count,
                  token: token(file.mtime),
                  mtime: file.mtime,
                )
            }
            return children.values.sorted { $0.name < $1.name }
          }
          return .entries(entries: entries)
        case let .rm(path, _):
          let removed = files.withLock { all in
            let doomed = all.keys.filter { $0 == path || $0.hasPrefix(path + "/") }
            for key in doomed {
              all[key] = nil
            }
            return doomed.count
          }
          return removed == 0 ? .error(error: .init(code: .notFound, message: "not found: \(path)")) : .ok
        case let .mv(from, to):
          return files.withLock { all in
            guard all[to] == nil else { return .error(error: .init(code: .conflict, message: "exists: \(to)")) }
            guard let file = all.removeValue(forKey: from) else {
              return .error(error: .init(code: .notFound, message: "not found: \(from)"))
            }
            all[to] = file
            return .ok
          }
        }
      },
      search: { _, _ in
        throw SearchError(.notFound, "search is unsupported in the fake")
      },
      attached: { [attached] in attached.value },
    )
  }
}

let machineA = MachineID(rawValue: "mc_aaaaaaaa")

// A machine side for execs: `serve` plays each started exec. Every exec gets
// its own machine endpoint, kept across re-dials so a rejoin finds the stream
// it left, and execs run side by side as they do behind the hub.
final class ScriptedExecMachine: Sendable {
  let startCount = Box(0)
  let kills = Box<[ExecID]>([])
  let failDelivered = Box(false)

  private let endpoints = Mutex<[ExecID: ChannelEndpoint]>([:])
  private let links = Mutex<[ExecID: InMemoryTransport]>([:])
  private let space = Mutex<Space?>(nil)
  private let transports: AsyncStream<(ChannelEndpoint, InMemoryTransport)>
  private let transportsContinuation: AsyncStream<(ChannelEndpoint, InMemoryTransport)>.Continuation
  private let fresh: AsyncStream<ChannelEndpoint>
  private let freshContinuation: AsyncStream<ChannelEndpoint>.Continuation

  private let onTerminalAck: @Sendable (Ack) async throws -> Void

  init(onTerminalAck: @escaping @Sendable (Ack) async throws -> Void = { _ in }) {
    self.onTerminalAck = onTerminalAck
    (transports, transportsContinuation) = AsyncStream.makeStream()
    (fresh, freshContinuation) = AsyncStream.makeStream()
  }

  func dial(_ id: ExecID) -> any FrameTransport {
    let (caller, machineSide) = InMemoryTransport.pair()
    links.withLock { $0[id] = machineSide }
    transportsContinuation.yield((endpoint(for: id), machineSide))
    return TerminalAckTransport(base: caller, observe: onTerminalAck)
  }

  func executor(
    owner: MainHub.Hub, jobs: ExecJobs = ExecJobs(), reachable: Bool = true, scripts: Scripts? = nil,
    access: InferenceAccess = InferenceAccess(), origin: String? = nil, contentHostPattern: String? = nil,
    secrets: SpaceSecretStores? = nil, identity: IdentityController? = nil,
  ) -> ToolExecutor {
    let space = owner.space
    self.space.withLock { $0 = space }
    let tokens = ExecTokens(spaceURL: "http://main")
    let connection = MainConnection()
    let executor = ToolExecutor(owner: owner, main: connection, credential: {
      guard reachable else { throw MainUnavailable() }
      return tokens.sessionToken($0)
    }, access: access, scripts: scripts, execJobs: jobs)
    let workers = WorkerRegistry(tokens: tokens, machines: nil)
    workers.announce(workers.mint().id, endpoint: ToolOnlyWorker())
    let fallback = FetchClient.inProcess(SessionRuntime.bindMain(
      owner: owner, workers: workers, tokens: tokens, connection: connection,
      origin: origin, contentHostPattern: contentHostPattern, credentials: access.credentials, secrets: secrets, identity: identity,
    ))
    connection.bind(FetchClient { [self] request in
      guard request.url.path == "/v1/exec" || request.url.path.hasPrefix("/v1/exec/") else { return try await fallback(request) }
      let bearer = String((request.headers["authorization"] ?? "").dropFirst(7))
      guard let session = tokens.session(ofBearer: bearer) else { return Response(status: .unauthorized) }
      if request.url.path == "/v1/exec" {
        if request.method == .post {
          let input = try await request.json(ExecMintInput.self)
          if let script = input.script {
            let record = try await space.mintScriptExec(machine: input.machine, caller: session.rawValue, script: script)
            return try Response.json(ExecMintOutput(id: record.id))
          }
          let callID = try #require(request.headers["wuhu-tool-call"])
          let claim = try await space.claimExec(machine: input.machine, caller: session.rawValue, toolCallID: .init(callID), spec: input.spec?.jsonString())
          return try Response.json(ExecMintOutput(id: claim.record.id))
        }
        return try Response.json(try await space.liveExecs().filter { $0.caller == session.rawValue }.map { execStatus(of: $0) })
      }
      let components = request.url.path.split(separator: "/")
      let id = ExecID(rawValue: String(components[2]))
      guard let record = try await space.execRecord(id), record.caller == session.rawValue else {
        return try Response.json(["code": "notFound", "message": "unknown exec"], status: .notFound)
      }
      if components.last == "detach" || components.last == "delivered" {
        if components.last == "delivered", failDelivered.value {
          return try Response.json(["code": "unavailable", "message": "injected delivery failure"], status: .serviceUnavailable)
        }
        guard try await space.setExecEndOwed(id, caller: session.rawValue, owed: components.last == "detach") else {
          return try Response.json(["code": "notFound", "message": "unknown tool exec"], status: .notFound)
        }
        return try Response.json([String: String]())
      }
      if components.last == "kill" {
        guard record.terminal == nil else {
          return try Response.json(["code": "alreadyEnded", "message": "exec has already ended"], status: .unprocessableContent)
        }
        kills.withLock { $0.append(id) }
        try await space.finishExec(id, .cancelled)
        return try Response.json(["ok": true])
      }
      return try Response.json(execStatus(of: record))
    }, dial: { [self] url, _ in
      guard reachable else { throw SpaceClient.DialRefusal(status: 422, body: []) }
      return dial(ExecID(rawValue: url.lastPathComponent))
    })
    return executor
  }

  private func endpoint(for id: ExecID) -> ChannelEndpoint {
    let (endpoint, created) = endpoints.withLock { endpoints in
      if let endpoint = endpoints[id] { return (endpoint, false) }
      let endpoint = ChannelEndpoint()
      endpoints[id] = endpoint
      return (endpoint, true)
    }
    if created { freshContinuation.yield(endpoint) }
    return endpoint
  }

  // The machine drops away as the hub sees it once the grace runs out: the
  // exec turns machine-lost and its caller leg is cut.
  func lose(_ id: ExecID) async {
    try? await space.withLock { $0 }?.finishExec(id, .machineLost)
    links.withLock { $0[id] }?.sever()
  }

  func pump() async {
    await withDiscardingTaskGroup { group in
      for await (endpoint, transport) in transports {
        group.addTask { [self] in
          guard let store = self.space.withLock({ $0 }) else { return }
          await endpoint.run(ExecRecordingTransport(base: transport, space: store))
        }
      }
    }
  }

  func serve(_ script: @escaping @Sendable (IncomingExec) async -> Void) async {
    await withDiscardingTaskGroup { group in
      for await endpoint in fresh {
        group.addTask { [startCount] in
          await withDiscardingTaskGroup { execs in
            for await exec in endpoint.incomingExecs {
              startCount.withLock { $0 += 1 }
              execs.addTask { await script(exec) }
            }
          }
        }
      }
    }
  }
}

struct Gate: Sendable {
  private let stream: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation

  init() {
    (stream, continuation) = AsyncStream.makeStream()
  }

  func open() {
    continuation.yield(())
  }

  func wait() async {
    var iterator = stream.makeAsyncIterator()
    _ = await iterator.next()
  }
}

private struct TerminalAckTransport: FrameTransport {
  let base: InMemoryTransport
  let observe: @Sendable (Ack) async throws -> Void
  var inbound: AsyncStream<[UInt8]> { base.inbound }
  func close() { base.close() }
  func send(_ bytes: [UInt8]) async throws {
    let frame = try FrameCodec.decode(bytes)
    if frame.opcode == .ack, let ack = try? frame.payload(Ack.self), ack.terminal == true {
      try await observe(ack)
    }
    try await base.send(bytes)
  }
}

private struct ExecRecordingTransport: FrameTransport {
  let base: InMemoryTransport
  let space: Space
  var inbound: AsyncStream<[UInt8]> { base.inbound }
  func close() { base.close() }
  func send(_ bytes: [UInt8]) async throws {
    let frame = try FrameCodec.decode(bytes)
    if frame.opcode == .execExit, let exit = try? frame.payload(ExecExit.self),
       try await space.execRecord(exit.id)?.terminal == nil
    {
      switch exit.status {
      case let .exited(code): try await space.finishExec(exit.id, .exited(code: code))
      case let .signaled(signal): try await space.finishExec(exit.id, .signaled(signal: signal))
      }
    }
    try await base.send(bytes)
  }
}
