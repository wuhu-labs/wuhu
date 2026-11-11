import SessionDomain
import enum SpaceCore.SessionRunState
import StructuredQueries
import struct WuhuAI.ToolCall
import WuweiQueries

/// Where a session's turn stands and what it owes, written by its cell in the step that writes the transcript: the cell's next move without reading the transcript back. While the typed transcript is stored, each step checks the row against its fold (`init(folding:generation:nags:)`), which wins.
@Table("session_state")
struct SessionTurn: Owned, Equatable, Encodable, Sendable {
  var generation: Int
  /// Items in the generation, which is where the next one goes.
  var position: Int
  @Column(as: Turn.JSONRepresentation.self) var turn: Turn
  /// The reads the generation's head asks for that are not answered yet. Empty once the generation has a reply of its own.
  @Column(as: [ToolCall].JSONRepresentation.self) var reestablish: [ToolCall]
  var replied: Bool
  /// Nil until the cell's next step takes it from the transcript: a row from before the column, or a generation Start over opened, whose head the store works out from the queue and the messages.
  @Column(as: NagState.JSONRepresentation?.self) var nags: NagState?
  /// Nil in a row from before the cell kept what the generation saw (`Seen`): the next step takes that from the transcript.
  var seen: Bool?
  /// Nil in a row from before the cell kept what the session armed (`Armed`): the next step takes that from the stores.
  var armed: Bool?

  enum Turn: Equatable, Codable, Sendable {
    /// A generation nothing was said in: created or started over.
    case inert
    /// The model owes a step, or the next of `reestablish` first.
    case model
    /// The calls of the model's reply that are not answered, in its order.
    case tools(calls: [ToolCall])
    /// The model spoke last.
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
    case .inert, .idle, .folding: .noRun
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
}

/// A turn row that differed from its transcript's fold, as the mismatch log takes it.
public struct TurnDifference: Sendable, Encodable {
  var time: String
  var session: String
  var stored: Side
  var folded: Side

  /// The row, or the rows of what the generation saw that the other side lacks.
  enum Side: Sendable, Encodable {
    case turn(SessionTurn)
    case seen([Seen])

    func encode(to encoder: any Encoder) throws {
      switch self {
      case let .turn(turn): try turn.encode(to: encoder)
      case let .seen(seen): try seen.encode(to: encoder)
      }
    }
  }
}

extension SessionTurn {
  init(folding transcript: Transcript, generation: Int, nags: NagState) {
    let pending = Set(transcript.pendingToolCallIDs.map(\.rawValue))
    let calls = transcript.items.flatMap { item -> [ToolCall] in
      guard case let .assistant(entry) = item else { return [] }
      return entry.toolCalls.filter { pending.contains($0.id) }
    }
    let turn: Turn = if case let .foldPending(call) = transcript.phase {
      .folding(call: call)
    } else if !calls.isEmpty {
      .tools(calls: calls)
    } else if transcript.hasWork {
      .model
    } else if case .assistant? = transcript.items.last {
      .idle
    } else {
      .inert
    }
    self.init(generation: generation, position: transcript.items.count, turn: turn, reestablish: transcript.reestablishments, replied: transcript.hasFreshReply, nags: nags, seen: true, armed: true)
  }
}

extension Transcript {
  fileprivate var hasFreshReply: Bool {
    items[keptCount...].contains { if case .assistant = $0 { true } else { false } }
  }

  /// The generation head's re-establishing reads that are not answered, while the generation has none of its own replies.
  var reestablishments: [ToolCall] {
    guard needsReestablishment, case let .generationHead(head) = items.first else { return [] }
    let done = items[keptCount...].count { item in
      if case let .toolResult(result) = item, result.provenance == .compactionReestablishment { true } else { false }
    }
    return Array(head.reestablishmentCalls.dropFirst(done))
  }
}
