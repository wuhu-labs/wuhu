#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain

public struct TranscriptCursor: Hashable, Sendable {
  public var generation: Int
  public var position: Int

  public init(generation: Int, position: Int) {
    self.generation = generation
    self.position = position
  }
}

public struct TranscriptPage: Hashable, Sendable {
  public var generation: Int
  public var startPosition: Int
  public var items: [TranscriptItem]
  // A reset page replaces everything the client holds: the cursor was absent
  // or named a superseded generation (compaction bumped it).
  public var reset: Bool
}

extension SessionStore {
  public func transcriptSnapshot(_ id: SessionID) async throws -> (generation: Int, items: [TranscriptItem]) {
    let key = id.rawValue
    return try await writer.read { db in
      let runtime = try Sessions.runtime(key, in: db)
      switch try Sessions.record(key, in: db).executor {
      case .kernel, .contractor:
        return (Int(runtime.generation), try Sessions.transcript(key, in: db).items)
      case .claudeCode:
        var transcript = ClaudeCodeTranscript(generation: runtime.generation)
        return (Int(runtime.generation), try Sessions.claudeCodeTranscript(key, advancing: &transcript, in: db))
      }
    }
  }

  public func observeTranscript(
    _ id: SessionID,
    from cursor: TranscriptCursor? = nil,
  ) -> AsyncThrowingStream<TranscriptPage, any Error> {
    let key = id.rawValue
    let writer = writer
    return observation(
      writer: writer,
      tables: ["session_pointers", "session_runtime"],
      state: TranscriptObservation(cursor: cursor),
    ) { db, state in
      let runtime = try Sessions.runtime(key, in: db)
      let generation = Int(runtime.generation)
      let reset = state.cursor?.generation != generation
      let start = reset ? 0 : state.cursor!.position + 1
      var next = state
      let items: [TranscriptItem]
      switch try Sessions.record(key, in: db).executor {
      case .kernel, .contractor:
        items = try Row.fetchAll(
          db,
          sql: """
          SELECT c.payload FROM session_pointers p
          JOIN session_contents c ON c.session_id = p.session_id AND c.id = p.content_id
          WHERE p.session_id = ? AND p.generation = ? AND p.position >= ?
          ORDER BY p.position
          """,
          arguments: [key, runtime.generation, start],
        ).map { try Sessions.decode(TranscriptItem.self, from: $0["payload"]) }
      case .claudeCode:
        // A reconnect retranslates the generation and skips what the client holds.
        var transcript = state.claudeCode.flatMap { $0.generation == runtime.generation ? $0 : nil }
          ?? ClaudeCodeTranscript(generation: runtime.generation)
        let fresh = try Sessions.claudeCodeTranscript(key, advancing: &transcript, in: db)
        next.claudeCode = transcript
        items = Array(fresh.dropFirst(max(0, start - (transcript.count - fresh.count))))
      }
      guard reset || !items.isEmpty else { return (nil, next) }
      next.cursor = TranscriptCursor(generation: generation, position: start + items.count - 1)
      return (TranscriptPage(generation: generation, startPosition: start, items: items, reset: reset), next)
    }
  }

  public func observeConversation(
    _ conversation: ConversationID,
    after n: Int64 = 0,
  ) -> AsyncThrowingStream<[MessageRecord], any Error> {
    let key = conversation.rawValue
    let writer = writer
    return observation(writer: writer, tables: ["messages"], state: n) { db, cursor in
      guard try Conversations.record(key, in: db) != nil else {
        throw SessionStoreError.unknownConversation(key)
      }
      let records = try Conversations.fetch(
        db,
        where: "conversation_id = ? AND n > ?",
        arguments: [key, cursor],
      )
      guard let last = records.last else { return (nil, cursor) }
      return (records, last.n)
    }
  }
}

private struct TranscriptObservation: Sendable {
  var cursor: TranscriptCursor?
  var claudeCode: ClaudeCodeTranscript?
}

// Cursor-native observation: each wakeup reads past the cursor in one snapshot
// and advances it, so the client-visible stream has no gaps and no duplicates
// regardless of how the region observation coalesces commits.
private func observation<State: Sendable, Element: Sendable>(
  writer: any DatabaseWriter,
  tables: [String],
  state: State,
  poll: @escaping @Sendable (Database, State) throws -> (Element?, State),
) -> AsyncThrowingStream<Element, any Error> {
  AsyncThrowingStream { continuation in
    let task = Task {
      let dirty = regionWakes(tables.map { Table($0) }, in: writer)
      var state = state
      do {
        func wake() async throws {
          let (element, next) = try await writer.read { [state] db in try poll(db, state) }
          state = next
          if let element { continuation.yield(element) }
        }
        try await wake()
        for await _ in dirty {
          if Task.isCancelled { break }
          try await wake()
        }
        continuation.finish()
      } catch {
        continuation.finish(throwing: error)
      }
    }
    continuation.onTermination = { _ in task.cancel() }
  }
}
