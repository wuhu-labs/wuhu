import Foundation

/// A single transcript entry.
///
/// The transcript is the canonical ordered log for a session. Some entries are "message entries"
/// that become LLM input; others exist only for diagnostics / UX.
public struct TranscriptItem: Sendable, Hashable, Codable {
  public var id: TranscriptEntryID
  public var createdAt: Date
  public var entry: Entry

  public init(id: TranscriptEntryID, createdAt: Date, entry: Entry) {
    self.id = id
    self.createdAt = createdAt
    self.entry = entry
  }
}

/// Domain-level entry types. UI rendering and grouping are separate concerns.
public enum Entry: Sendable, Hashable, Codable {
  case message(MessageEntry)
  case marker(MarkerEntry)
  case tool(ToolEntry)
  case diagnostic(DiagnosticEntry)
}

/// A message that is eligible to be included in the LLM context.
public struct MessageEntry: Sendable, Hashable, Codable {
  public var author: Author
  public var content: MessageContent

  public init(author: Author, content: MessageContent) {
    self.author = author
    self.content = content
  }
}

public enum MessageContent: Sendable, Hashable, Codable {
  case text(String)
}

/// Non-message markers that help describe execution boundaries or session lifecycle.
public enum MarkerEntry: Sendable, Hashable, Codable {
  case executionStopped(by: Author)
  case executionResumed(trigger: Author)
  case participantJoined(Author)
}

/// Tool execution surface (can be rendered and/or summarized in UI).
public struct ToolEntry: Sendable, Hashable, Codable {
  public var name: String
  public var detail: String?

  public init(name: String, detail: String? = nil) {
    self.name = name
    self.detail = detail
  }
}

/// Diagnostic / non-causal entries (transport errors, server overload, etc.).
public struct DiagnosticEntry: Sendable, Hashable, Codable {
  public var message: String

  public init(message: String) {
    self.message = message
  }
}

/// A page of transcript items for catch-up.
public struct TranscriptPage: Sendable, Hashable, Codable {
  public var items: [TranscriptItem]
  public var nextCursor: TranscriptCursor?

  public init(items: [TranscriptItem], nextCursor: TranscriptCursor?) {
    self.items = items
    self.nextCursor = nextCursor
  }
}
