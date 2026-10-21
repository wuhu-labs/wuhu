#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import enum InferenceKit.AttemptEvent
import protocol MachineChannel.FrameTransport
import SessionDomain
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
  case shutdown
}

enum WorkerLineMessage: Codable, Sendable {
  case call(id: Int, WorkerCall)
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
  }

  var id: UUID
  var path: String
  var session: SessionID
  var input: Input
  var stateJSON: String?

  init(_ invocation: ScriptHandlerInvocation) {
    id = invocation.id
    path = invocation.path
    session = invocation.session
    stateJSON = invocation.stateJSON
    input = switch invocation.input {
    case let .rows(rows): .rows(columns: rows.columns, decltypes: rows.decltypes, rows: rows.rows.map { $0.map(WireCell.init) })
    case let .timer(date): .timer(date.timeIntervalSince1970)
    }
  }

  var invocation: ScriptHandlerInvocation {
    let input: ScriptHandlerInvocation.Input = switch self.input {
    case let .rows(columns, decltypes, rows): .rows(Rows(columns: columns, decltypes: decltypes, rows: rows.map { $0.map(\.cell) }))
    case let .timer(seconds): .timer(Date(timeIntervalSince1970: seconds))
    }
    return ScriptHandlerInvocation(id: id, path: path, session: session, input: input, stateJSON: stateJSON)
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
  private struct State {
    var next = 0
    var waiting: [Int: CheckedContinuation<WorkerReply, any Error>] = [:]
    var closed = false
  }

  private let transport: any FrameTransport
  private let state = Mutex(State())
  private let onNotice: @Sendable (WorkerNotice) -> Void

  public init(transport: any FrameTransport, onNotice: @escaping @Sendable (WorkerNotice) -> Void = { _ in }) {
    self.transport = transport
    self.onNotice = onNotice
  }

  public func run() async {
    for await frame in transport.inbound {
      switch try? JSONDecoder().decode(WorkerLineMessage.self, from: Data(frame)) {
      case let .reply(id, reply)?: state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(returning: reply)
      case let .notice(notice)?: onNotice(notice)
      case .call?, nil: continue
      }
    }
    let waiting = state.withLock { state in
      state.closed = true
      defer { state.waiting = [:] }
      return Array(state.waiting.values)
    }
    for call in waiting { call.resume(throwing: WorkerLineSevered()) }
  }

  public func close() { transport.close() }

  private func ask(_ call: WorkerCall) async throws -> WorkerReply {
    let reply: WorkerReply = try await withCheckedThrowingContinuation { continuation in
      let id = state.withLock { state -> Int? in
        guard !state.closed else { return nil }
        state.next += 1
        state.waiting[state.next] = continuation
        return state.next
      }
      guard let id else { return continuation.resume(throwing: WorkerLineSevered()) }
      Task {
        do { try await transport.send(Array(JSONEncoder().encode(WorkerLineMessage.call(id: id, call)))) }
        catch { state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(throwing: WorkerLineSevered()) }
      }
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
    for await frame in transport.inbound {
      guard case let .call(id, call)? = try? JSONDecoder().decode(WorkerLineMessage.self, from: Data(frame)) else { continue }
      group.addTask {
        let reply: WorkerReply
        do { reply = try await answer(call, with: worker) } catch { reply = .failed(WireError(error)) }
        guard let frame = try? JSONEncoder().encode(WorkerLineMessage.reply(id: id, reply)) else { return }
        try? await transport.send(Array(frame))
      }
    }
    group.cancelAll()
  }
}

private func answer(_ call: WorkerCall, with worker: any Worker) async throws -> WorkerReply {
  switch call {
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
