import SessionDomain
import enum SpaceCore.SessionRunState
import StructuredQueries
import struct WuhuAI.ToolCall
import WuweiQueries
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

/// The session cell's durable next move, written with its lines.
@Table("session_state")
struct SessionTurn: Owned, Equatable, Sendable {
  var generation: Int
  /// A counter of cell writes, naming job slots independently of line positions.
  var position: Int
  @Column(as: Turn.JSONRepresentation.self) var turn: Turn
  /// The reads the generation's head asks for that are not answered yet. Empty once the generation has a reply of its own.
  @Column(as: [ToolCall].JSONRepresentation.self) var reestablish: [ToolCall]
  var replied: Bool
  @Column(as: NagState.JSONRepresentation?.self) var nags: NagState?
  var seen: Bool?
  var armed: Bool?

  @Column(as: [TranscriptLine].JSONRepresentation?.self) var held: [TranscriptLine]? = nil
  @Column(as: ReplayBinding.JSONRepresentation?.self) var binding: ReplayBinding? = nil
  @Column(as: [String: Int].JSONRepresentation?.self) var bookmarks: [String: Int]? = nil
  var origin: Bool? = nil
  /// Cache warming the last reply left, or nil when warming is off.
  @Column(as: Warming.JSONRepresentation?.self) var warming: Warming? = nil

  enum Turn: Equatable, Codable, Sendable {
    /// A generation nothing was said in: created or started over.
    case inert
    case converting
    /// The model owes a step, or the next of `reestablish` first.
    case model
    /// The calls of the model's reply that are not answered, in its order.
    case tools(calls: [ToolCall])
    /// Nothing is owed until the next input: the model spoke last, or its ping never answered.
    case idle
    /// Parked by this compact call: the next delivery runs the fold.
    case folding(call: ToolCallID)
  }

  /// The first of the reply's calls that is not answered.
  var call: ToolCall? {
    if case let .tools(calls) = turn { calls.first } else { nil }
  }

  var owed: SessionRunState {
    switch turn {
    case .tools: .tool
    case .model: .inference
    case .inert, .idle, .folding, .converting: .noRun
    }
  }

  /// The model's reply.
  mutating func reply(_ calls: [ToolCall]) {
    position += 1
    replied = true
    reestablish = []
    turn = calls.isEmpty ? .idle : .tools(calls: calls)
  }

  /// `count` inputs or notices went after the tail.
  mutating func input(_ count: Int) {
    guard count > 0 else { return }
    position += count
    if turn == .idle || turn == .inert { turn = .model }
  }

  /// The answer to one of the reply's calls.
  mutating func answer(_ call: ToolCallID) {
    position += 1
    guard case var .tools(calls) = turn else { return }
    calls.removeAll { $0.id == call.rawValue }
    turn = calls.isEmpty ? .model : .tools(calls: calls)
  }

  /// The answer to the first of `reestablish`.
  mutating func reestablished() {
    position += 1
    reestablish = Array(reestablish.dropFirst())
  }

  /// The answer to a compact call that parks: the reply's other calls go unanswered.
  mutating func park(_ call: ToolCallID) {
    position += 1
    turn = .folding(call: call)
  }

  /// A reply's warming as of this cell taking it: none ends it, real input starts it at a fresh count, and a reply to anything else only moves one that still exists — warming that ended stays ended until real input.
  mutating func warmed(_ schedule: WarmingSchedule?, at now: Date) {
    guard let schedule else {
      warming = nil
      return
    }
    if origin == false {
      warming = Warming(schedule: schedule, repliedAt: now.timeIntervalSinceReferenceDate, pings: 0)
    } else if var warming {
      warming.schedule = schedule
      warming.repliedAt = now.timeIntervalSinceReferenceDate
      self.warming = warming
    }
  }

  /// A ping whose only attempt failed: nothing more is owed, and the notice stays an unanswered line.
  mutating func pingUnanswered() {
    position += 1
    turn = .idle
  }

  /// A ping the wake started, with the notice as its input: the count moves here, and the reply moves the time the next one counts from.
  mutating func pinged() {
    warming!.pings += 1
    input(1)
  }
}

extension SessionTurn {
  init(generation: Int, position: Int) {
    self.init(generation: generation, position: position, turn: .inert, reestablish: [], replied: false, nags: NagState(), seen: true, armed: nil)
  }
}

/// What a session keeps of a reply's warming: the schedule, when the reply landed on the cell's clock, and the pings spent since.
struct Warming: Hashable, Codable, Sendable {
  var schedule: WarmingSchedule
  /// Since the reference date, which round-trips a `Date` exactly.
  var repliedAt: Double
  var pings: Int
}
