#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct FetchSSE.SSEEvent
import enum InferenceKit.AttemptEvent
import protocol MachineChannel.FrameTransport
import SessionDomain
import struct SpaceContract.GroupID
import enum SpaceContract.ScriptOutput
import struct SpaceContract.UsageWindow
import SpaceCore
import Synchronization

// The worker's line: one connection the worker opens to main, over which
// main asks the `Worker` calls and the worker answers them. Each frame is one
// JSON message; calls run at once, side by side, and each reply names its
// call. `WorkerClient` is main's end, `serveWorkerLine` the worker's.

/// Where a worker opens its line to main, with its own token.
public let workerLinePath = "/v1/worker/line"
/// The sessions a worker holds as it opens its line, comma-separated: main
/// keeps them on it.
public let workerHoldingHeader = "wuhu-worker-holding"

/// The line to the worker closed before the call was answered.
public struct WorkerLineSevered: Error, CustomStringConvertible {
  public init() {}
  public var description: String { "the line to the worker closed" }
}

/// The worker's refusal of a call, by what it said, when main does not act
/// on its kind.
public struct WorkerFailure: Error, CustomStringConvertible, Equatable {
  public let message: String
  public var description: String { message }
}

enum WorkerCall: Codable, Sendable {
  case deliver(session: SessionID, input: WorkerInput)
  case revoke(session: SessionID, policy: RevocationPolicy)
  case fire(WireInvocation)
  case activity
  case runningWork(session: SessionID)
  case run(ScriptRun)
  case shutdown

  // A script or a firing stops when main stops waiting; every other call
  // finishes what it started.
  var cancellable: Bool {
    switch self {
    case .run, .fire: true
    case .deliver, .revoke, .activity, .runningWork, .shutdown: false
    }
  }
}

// A call's outputs all cross before its reply; a cancel for a call that is
// not running is dropped.
enum WorkerLineMessage: Codable, Sendable {
  case call(id: Int, WorkerCall)
  case cancel(id: Int)
  case output(id: Int, ScriptOutput)
  case reply(id: Int, WorkerReply)
  case notice(WorkerNotice)
}

/// What a worker tells main unasked, as it happens: its inferences' streams
/// and the plan usage providers report. Main keeps both in memory only.
public enum WorkerNotice: Codable, Sendable {
  case attempt(session: SessionID, event: AttemptEvent)
  case usage(provider: String, plan: String?, windows: [UsageWindow], at: Double)
}

/// The notices a worker has for main, in order, until its line sends them.
/// Each line the worker opens takes them from then on; those sent while no
/// line takes them wait for the next one, the newest 4096 of them.
public final class WorkerNotices: Sendable {
  private typealias Pair = (stream: AsyncStream<WorkerNotice>, continuation: AsyncStream<WorkerNotice>.Continuation)

  private struct State {
    var active: AsyncStream<WorkerNotice>.Continuation?
    var pending: Pair
  }

  private let state: Mutex<State>

  private static func pair() -> Pair { AsyncStream.makeStream(of: WorkerNotice.self, bufferingPolicy: .bufferingNewest(4096)) }

  public init() {
    state = Mutex(State(active: nil, pending: Self.pair()))
  }

  public func send(_ notice: WorkerNotice) {
    state.withLock { state in
      if let active = state.active, case .terminated = active.yield(notice) { state.active = nil }
      if state.active == nil { state.pending.continuation.yield(notice) }
    }
  }

  // The notices for the line opening now; the line before it gets no more.
  func subscribe() -> AsyncStream<WorkerNotice> {
    state.withLock { state in
      state.active?.finish()
      let taken = state.pending
      state.active = taken.continuation
      state.pending = Self.pair()
      return taken.stream
    }
  }
}

enum WorkerReply: Codable, Sendable {
  case done
  case settled(Bool)
  case handled(stateJSON: String, wakes: [String])
  case activity(scripts: [ScriptOfSession])
  case running([String])
  case failed(WireError)
}

struct ScriptOfSession: Codable, Sendable {
  var script: String
  var session: SessionID
}

// A handler's invocation as it crosses: dates as seconds, rows cell by cell.
struct WireInvocation: Codable, Sendable {
  enum Input: Codable, Sendable {
    case rows(columns: [String], decltypes: [String?], rows: [[WireCell]])
    case timer(Double)
    case event(id: String?, type: String, data: String)
  }

  enum Runner: Codable, Sendable {
    case session(SessionID)
    case observer(group: String, name: String, firing: String?, token: String)
  }

  var id: UUID
  var path: String
  var runner: Runner
  var input: Input
  var stateJSON: String?

  init(_ invocation: ScriptHandlerInvocation) {
    id = invocation.id
    path = invocation.path
    switch invocation.runner {
    case let .session(id): runner = .session(id)
    case let .observer(observer):
      guard let token = invocation.token else { preconditionFailure("an observer's firing crosses to a worker with its token") }
      runner = .observer(group: observer.group.rawValue, name: observer.name, firing: observer.firing, token: token)
    }
    stateJSON = invocation.stateJSON
    input = switch invocation.input {
    case let .rows(rows): .rows(columns: rows.columns, decltypes: rows.decltypes, rows: rows.rows.map { $0.map(WireCell.init) })
    case let .timer(date): .timer(date.timeIntervalSince1970)
    case let .event(event): .event(id: event.id, type: event.event, data: event.data)
    }
  }

  var invocation: ScriptHandlerInvocation {
    let input: ScriptHandlerInvocation.Input = switch self.input {
    case let .rows(columns, decltypes, rows): .rows(Rows(columns: columns, decltypes: decltypes, rows: rows.map { $0.map(\.cell) }))
    case let .timer(seconds): .timer(Date(timeIntervalSince1970: seconds))
    case let .event(id, type, data): .event(SSEEvent(event: type, data: data, id: id))
    }
    let runner: ScriptHandlerInvocation.Runner
    let token: String?
    switch self.runner {
    case let .session(id): runner = .session(id); token = nil
    case let .observer(group, name, firing, minted):
      runner = .observer(Observer(group: GroupID(rawValue: group), name: name, firing: firing)); token = minted
    }
    return ScriptHandlerInvocation(id: id, path: path, runner: runner, input: input, stateJSON: stateJSON, token: token)
  }
}

enum WireCell: Codable, Sendable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob([UInt8])

  init(_ cell: Cell) {
    self = switch cell {
    case .null: .null
    case let .integer(value): .integer(value)
    case let .real(value): .real(value)
    case let .text(value): .text(value)
    case let .blob(value): .blob(value)
    }
  }

  var cell: Cell {
    switch self {
    case .null: .null
    case let .integer(value): .integer(value)
    case let .real(value): .real(value)
    case let .text(value): .text(value)
    case let .blob(value): .blob(value)
    }
  }
}

// The errors main acts on cross by kind; any other by what it says.
enum WireError: Codable, Sendable {
  case session(SessionWireError)
  case unfulfilled
  case cancelled
  case other(String)

  enum SessionWireError: Codable, Sendable {
    case unreadableData(SessionID)
    case archiveGraceExpired
    case archiveInProgress
    case archiveReservationLost
  }

  init(_ error: any Error) {
    switch error {
    case let error as SessionError:
      self = switch error {
      case let .unreadableData(id): .session(.unreadableData(id))
      case .archiveGraceExpired: .session(.archiveGraceExpired)
      case .archiveInProgress: .session(.archiveInProgress)
      case .archiveReservationLost: .session(.archiveReservationLost)
      }
    case is UnfulfilledError: self = .unfulfilled
    case is CancellationError: self = .cancelled
    default: self = .other(String(describing: error))
    }
  }

  var error: any Error {
    switch self {
    case let .session(.unreadableData(id)): SessionError.unreadableData(id)
    case .session(.archiveGraceExpired): SessionError.archiveGraceExpired
    case .session(.archiveInProgress): SessionError.archiveInProgress
    case .session(.archiveReservationLost): SessionError.archiveReservationLost
    case .unfulfilled: UnfulfilledError()
    case .cancelled: CancellationError()
    case let .other(message): WorkerFailure(message: message)
    }
  }
}

/// Main's end of a worker's line: the `Worker` main's registry holds for it.
/// `run` reads the worker's replies until the line closes; a call still
/// waiting then fails with `WorkerLineSevered`, as does any call after.
public final class WorkerClient: Worker, Sendable {
  private struct Waiting {
    let reply: CheckedContinuation<WorkerReply, any Error>
    let output: (@Sendable (ScriptOutput) -> Void)?
  }

  private struct State {
    var next = 0
    var waiting: [Int: Waiting] = [:]
    var closed = false
  }

  private let transport: any FrameTransport
  private let state = Mutex(State())
  private let onNotice: @Sendable (WorkerNotice) -> Void
  private let outbound: AsyncStream<WorkerLineMessage>
  private let send: AsyncStream<WorkerLineMessage>.Continuation

  public init(transport: any FrameTransport, onNotice: @escaping @Sendable (WorkerNotice) -> Void = { _ in }) {
    self.transport = transport
    self.onNotice = onNotice
    (outbound, send) = AsyncStream.makeStream()
  }

  public func run() async {
    await withDiscardingTaskGroup { group in
      group.addTask { [outbound, transport] in
        for await message in outbound {
          guard let frame = try? JSONEncoder().encode(message) else { continue }
          do { try await transport.send(Array(frame)) } catch { return transport.close() }
        }
      }
      for await frame in transport.inbound {
        switch try? JSONDecoder().decode(WorkerLineMessage.self, from: Data(frame)) {
        case let .reply(id, reply)?: state.withLock { $0.waiting.removeValue(forKey: id) }?.reply.resume(returning: reply)
        case let .output(id, output)?: state.withLock { $0.waiting[id]?.output }?(output)
        case let .notice(notice)?: onNotice(notice)
        case .call?, .cancel?, nil: continue
        }
      }
      send.finish()
    }
    let waiting = state.withLock { state in
      state.closed = true
      defer { state.waiting = [:] }
      return Array(state.waiting.values)
    }
    for call in waiting { call.reply.resume(throwing: WorkerLineSevered()) }
  }

  public func close() { transport.close() }

  private func ask(_ call: WorkerCall, output: (@Sendable (ScriptOutput) -> Void)? = nil) async throws -> WorkerReply {
    let id = state.withLock { state in
      state.next += 1
      return state.next
    }
    let reply: WorkerReply = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let open = state.withLock { state in
          guard !state.closed else { return false }
          state.waiting[id] = Waiting(reply: continuation, output: output)
          return true
        }
        guard open else { return continuation.resume(throwing: WorkerLineSevered()) }
        send.yield(.call(id: id, call))
        if call.cancellable, Task.isCancelled { send.yield(.cancel(id: id)) }
      }
    } onCancel: {
      if call.cancellable { send.yield(.cancel(id: id)) }
    }
    if case let .failed(error) = reply { throw error.error }
    return reply
  }

  private struct UnexpectedReply: Error, CustomStringConvertible {
    let reply: WorkerReply
    var description: String { "the worker answered out of turn: \(reply)" }
  }

  public func deliver(_ session: SessionID, _ input: WorkerInput) async throws {
    let reply = try await ask(.deliver(session: session, input: input))
    guard case .done = reply else { throw UnexpectedReply(reply: reply) }
  }

  public func revoke(_ session: SessionID, policy: RevocationPolicy) async throws -> Bool {
    let reply = try await ask(.revoke(session: session, policy: policy))
    guard case let .settled(settled) = reply else { throw UnexpectedReply(reply: reply) }
    return settled
  }

  public func fire(_ invocation: ScriptHandlerInvocation) async throws -> ScriptHandlerResult {
    let reply = try await ask(.fire(WireInvocation(invocation)))
    guard case let .handled(stateJSON, wakes) = reply else { throw UnexpectedReply(reply: reply) }
    return ScriptHandlerResult(stateJSON: stateJSON, wakes: wakes)
  }

  // A worker that cannot be asked runs nothing main can name.
  public func activity() async -> WorkerActivity {
    guard case let .activity(scripts)? = try? await ask(.activity) else { return WorkerActivity(scripts: [:]) }
    return WorkerActivity(scripts: Dictionary(scripts.map { (ScriptRunID($0.script), $0.session) }) { _, last in last })
  }

  public func run(_ script: ScriptRun, output: @escaping @Sendable (ScriptOutput) -> Void) async throws {
    let reply = try await ask(.run(script), output: output)
    guard case .done = reply else { throw UnexpectedReply(reply: reply) }
  }

  public func runningWork(_ session: SessionID) async throws -> [String] {
    let reply = try await ask(.runningWork(session: session))
    guard case let .running(handles) = reply else { throw UnexpectedReply(reply: reply) }
    return handles
  }

  public func shutdown() async {
    _ = try? await ask(.shutdown)
  }
}

/// The worker's end of its line: answers main's calls on `transport` with
/// `worker` until the line closes, each call as it comes, side by side, and
/// sends `notices` as they come.
public func serveWorkerLine(_ worker: any Worker, on transport: any FrameTransport, notices: WorkerNotices? = nil) async {
  await withDiscardingTaskGroup { group in
    if let notices {
      let stream = notices.subscribe()
      group.addTask {
        for await notice in stream {
          guard let frame = try? JSONEncoder().encode(WorkerLineMessage.notice(notice)) else { continue }
          do { try await transport.send(Array(frame)) } catch { return }
        }
      }
    }
    let cancels = Mutex<[Int: AsyncStream<Void>.Continuation]>([:])
    for await frame in transport.inbound {
      switch try? JSONDecoder().decode(WorkerLineMessage.self, from: Data(frame)) {
      case let .call(id, call)?:
        let (cancelled, cancel) = AsyncStream<Void>.makeStream()
        cancels.withLock { $0[id] = cancel }
        group.addTask {
          // A cancelled call still replies: main waits for its reply.
          let reply = await withTaskGroup(of: WorkerReply?.self, returning: WorkerReply.self) { race in
            race.addTask {
              do { return try await answer(call, with: worker) { output in await send(.output(id: id, output), on: transport) } }
              catch { return .failed(WireError(error)) }
            }
            race.addTask {
              for await _ in cancelled {}
              return nil
            }
            while let finished = await race.next() {
              race.cancelAll()
              if let finished { return finished }
            }
            preconditionFailure("the answer always replies")
          }
          cancels.withLock { _ = $0.removeValue(forKey: id) }
          await send(.reply(id: id, reply), on: transport)
        }
      case let .cancel(id)?:
        cancels.withLock { $0[id] }?.finish()
      case .reply?, .output?, .notice?, nil:
        continue
      }
    }
    group.cancelAll()
  }
}

private func send(_ message: WorkerLineMessage, on transport: any FrameTransport) async {
  guard let frame = try? JSONEncoder().encode(message) else { return }
  try? await transport.send(Array(frame))
}

private func answer(
  _ call: WorkerCall, with worker: any Worker, output: @escaping @Sendable (ScriptOutput) async -> Void,
) async throws -> WorkerReply {
  switch call {
  case let .run(script):
    let (outputs, sink) = AsyncStream<ScriptOutput>.makeStream()
    async let sent: Void = { for await item in outputs { await output(item) } }()
    let ran: Result<Void, any Error>
    do { ran = .success(try await worker.run(script) { sink.yield($0) }) } catch { ran = .failure(error) }
    sink.finish()
    await sent
    try ran.get()
    return .done
  case let .deliver(session, input):
    try await worker.deliver(session, input)
    return .done
  case let .revoke(session, policy):
    return .settled(try await worker.revoke(session, policy: policy))
  case let .fire(invocation):
    let result = try await worker.fire(invocation.invocation)
    return .handled(stateJSON: result.stateJSON, wakes: result.wakes)
  case .activity:
    let scripts = await worker.activity().scripts
    return .activity(scripts: scripts.map { ScriptOfSession(script: $0.key.rawValue, session: $0.value) }.sorted { $0.script < $1.script })
  case let .runningWork(session):
    return .running(try await worker.runningWork(session))
  case .shutdown:
    await worker.shutdown()
    return .done
  }
}
