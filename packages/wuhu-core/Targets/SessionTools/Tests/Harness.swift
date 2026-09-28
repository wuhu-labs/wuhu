import Clocks
import ControlledTime
import Dependencies
import Foundation
import JSONValue
import MachineChannel
import struct MachineContract.Base64Data
import struct MachineContract.ExecID
import struct MachineContract.MachineEntry
import struct MachineContract.MachineError
import struct MachineContract.MachineID
import enum MachineContract.VFSDefaults
import enum MachineContract.VFSOp
import enum MachineContract.VFSResult
import SessionDomain
@testable import SessionTools
import struct SpaceContract.GroupID
import SpaceCore
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
  let executor: ToolExecutor
  let session: SessionID
  var state = ToolExecutionState()
  var delivered: ScopeContext?
  private var mintedCalls = 0

  init(executor: ToolExecutor, session: SessionID) {
    self.executor = executor
    self.session = session
  }

  mutating func run(
    _ name: String,
    _ arguments: ToolArguments,
    id explicit: String? = nil,
  ) async throws -> ToolResultPayload {
    mintedCalls += 1
    let id = explicit ?? "tc-\(mintedCalls)"
    let payload = try await executor.execute(
      session: session,
      call: ToolCall(id: id, name: name, arguments: arguments),
      state: state,
    )
    state.apply(payload)
    delivered = try await executor.store.scopeContext(session, toolCallID: ToolCallID(id))
    if let delivered {
      state.apply(delivered: .notification(delivered.notice(id: UUID(), at: Date(timeIntervalSince1970: 0))))
    }
    return payload
  }

  // A crash-retry: the kernel never committed the first result, so the retry
  // dispatches against the OLD state under the SAME kernel tool call id.
  func retry(
    _ name: String,
    _ arguments: ToolArguments,
    id: String,
  ) async throws -> ToolResultPayload {
    try await executor.execute(
      session: session,
      call: ToolCall(id: id, name: name, arguments: arguments),
      state: state,
    )
  }
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
  let reads = Box<[VFSOp]>([])

  init(ranges: Bool = true) {
    self.ranges = ranges
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
    MachineSeam(
      vfs: { [files, clockSeconds, stats, ranges, reads, replacedAfterStat] _, op in
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
            return .file(token: String(file.mtime), data: .init(file.content))
          }
          let start = min(offset ?? 0, file.content.count)
          let end = min(start + (length ?? file.content.count), file.content.count)
          return .file(token: String(file.mtime), data: .init(Array(file.content[start ..< end])))
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
              token: String(file.mtime),
              mtime: file.mtime,
            ))
          }
          guard files.withLock({ $0.keys.contains { $0.hasPrefix(path + "/") } }) else {
            return .error(error: .init(code: .notFound, message: "not found: \(path)"))
          }
          return .entry(entry: .init(name: name, kind: .directory, size: 0, token: "", mtime: 0))
        case let .write(path, data, _):
          let mtime = clockSeconds.withLock { seconds -> Double in
            seconds += 1
            return seconds
          }
          files.withLock { $0[path] = File(mtime: mtime, content: data.bytes) }
          return .written(token: String(mtime))
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
                  token: String(file.mtime),
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
        .error(error: .init(code: .invalidArgument, message: "unsupported in fake"))
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

  private let endpoints = Mutex<[ExecID: ChannelEndpoint]>([:])
  private let links = Mutex<[ExecID: InMemoryTransport]>([:])
  private let space = Mutex<Space?>(nil)
  private let transports: AsyncStream<(ChannelEndpoint, InMemoryTransport)>
  private let transportsContinuation: AsyncStream<(ChannelEndpoint, InMemoryTransport)>.Continuation
  private let fresh: AsyncStream<ChannelEndpoint>
  private let freshContinuation: AsyncStream<ChannelEndpoint>.Continuation

  init() {
    (transports, transportsContinuation) = AsyncStream.makeStream()
    (fresh, freshContinuation) = AsyncStream.makeStream()
  }

  func backend(_ space: Space) -> ExecBackend {
    self.space.withLock { $0 = space }
    return ExecBackend(
      claim: { machine, session, callID in
        try await space.claimExec(machine: machine, caller: session.rawValue, toolCallID: callID)
      },
      connect: { [self] id in
        let (caller, machineSide) = InMemoryTransport.pair()
        links.withLock { $0[id] = machineSide }
        transportsContinuation.yield((endpoint(for: id), machineSide))
        return caller
      },
      status: { id in try await space.execRecord(id) },
      mintScript: { machine, session, script in
        try await space.mintScriptExec(machine: machine, session: session.rawValue, script: script)
      },
      kill: { [kills] id in
        kills.withLock { $0.append(id) }
        try? await space.finishExec(id, .cancelled)
      },
    )
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
        group.addTask { await endpoint.run(transport) }
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
