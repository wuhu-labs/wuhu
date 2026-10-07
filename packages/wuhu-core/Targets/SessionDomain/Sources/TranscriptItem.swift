#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import struct SpaceContract.GroupID
import WuhuAI

public enum TranscriptItem: Hashable, Sendable, Codable {
  case direct(DirectMessage)
  case message(ConversationMessage)
  case notification(SystemNotification)
  case assistant(AssistantEntry)
  case toolResult(ToolResultItem)
  case bookmark(BookmarkMarker)
  case generationHead(GenerationHead)
}

public struct DirectMessage: Hashable, Sendable, Codable {
  public var id: UUID
  public var sender: Sender
  public var timestamp: Date
  public var content: MessageContent

  public init(id: UUID, sender: Sender, timestamp: Date, content: MessageContent) {
    self.id = id
    self.sender = sender
    self.timestamp = timestamp
    self.content = content
  }
}

public struct ConversationMessage: Hashable, Sendable, Codable {
  public var id: UUID
  public var messageID: MessageID
  public var conversationID: ConversationID
  public var sender: Sender
  public var senderSession: SessionID?
  public var timestamp: Date
  public var kind: MessageKind
  public var requestID: RequestID?
  public var deadline: Date?
  public var replyTarget: MessageID?
  // Per-delivery, minted by the delivery path: only it knows whether this
  // recipient owes the conversation an answer. The same row delivered to two
  // sessions carries two different answers.
  public var owesReply: Bool
  // Per-delivery too, frozen then so the prompt holds still: the sender's
  // group when it is not the recipient's, and whether the sender is an admin
  // of the recipient's group. Deliveries from before groups carry neither.
  public var senderGroup: GroupID?
  public var senderAdmin: Bool?
  public var content: MessageContent

  public init(
    id: UUID,
    messageID: MessageID,
    conversationID: ConversationID,
    sender: Sender,
    senderSession: SessionID? = nil,
    timestamp: Date,
    kind: MessageKind = .message,
    requestID: RequestID? = nil,
    deadline: Date? = nil,
    replyTarget: MessageID? = nil,
    owesReply: Bool = false,
    senderGroup: GroupID? = nil,
    senderAdmin: Bool? = nil,
    content: MessageContent,
  ) {
    self.id = id
    self.messageID = messageID
    self.conversationID = conversationID
    self.sender = sender
    self.senderSession = senderSession
    self.timestamp = timestamp
    self.kind = kind
    self.requestID = requestID
    self.deadline = deadline
    self.replyTarget = replyTarget
    self.owesReply = owesReply
    self.senderGroup = senderGroup
    self.senderAdmin = senderAdmin
    self.content = content
  }
}

public struct SystemNotification: Hashable, Sendable, Codable {
  public enum Kind: String, Hashable, Sendable, Codable {
    case timer
    case spaceObservation
    case compactRequest
    case owedReply
    case parkReminder
    case childFailed
    case requestDeadline
    case script
    case context
  }

  public var id: UUID
  public var timestamp: Date
  public var kind: Kind
  public var subscriptionID: SubscriptionID
  public var endsSubscription: Bool
  public var conversations: [ConversationID]
  public var requestID: RequestID?
  public var folderRoots: [String: String?]?
  public var content: MessageContent

  public init(
    id: UUID,
    timestamp: Date,
    kind: Kind,
    subscriptionID: SubscriptionID,
    endsSubscription: Bool = false,
    conversations: [ConversationID] = [],
    requestID: RequestID? = nil,
    folderRoots: [String: String?]? = nil,
    content: MessageContent,
  ) {
    self.id = id
    self.timestamp = timestamp
    self.kind = kind
    self.subscriptionID = subscriptionID
    self.endsSubscription = endsSubscription
    self.conversations = conversations
    self.requestID = requestID
    self.folderRoots = folderRoots
    self.content = content
  }
}

public struct AssistantEntry: Hashable, Sendable, Codable {
  public var id: UUID
  public var timestamp: Date
  // Tool-call blocks carry kernel-minted ids; toolCallIDs maps the per-turn
  // provider ids they replaced.
  public var content: [ContentBlock]
  public var stopReason: StopReason
  public var usage: Usage
  public var toolCallIDs: [String: ToolCallID]

  public init(
    id: UUID,
    timestamp: Date,
    content: [ContentBlock],
    stopReason: StopReason,
    usage: Usage,
    toolCallIDs: [String: ToolCallID],
  ) {
    self.id = id
    self.timestamp = timestamp
    self.content = content
    self.stopReason = stopReason
    self.usage = usage
    self.toolCallIDs = toolCallIDs
  }

  public var toolCalls: [ToolCall] {
    content.compactMap { block in
      guard case let .toolCall(call) = block else { return nil }
      return call
    }
  }
}

public struct BookmarkMarker: Hashable, Sendable, Codable {
  public var id: UUID
  public var timestamp: Date
  public var name: String?
  public var toolCallID: ToolCallID?

  public init(id: UUID, timestamp: Date, name: String? = nil, toolCallID: ToolCallID? = nil) {
    self.id = id
    self.timestamp = timestamp
    self.name = name
    self.toolCallID = toolCallID
  }
}

// `summary` is what a compaction folded; `note` is a line addressed to the
// session about the generation itself. A note is context, never a prompt: it
// renders at the head of the next real turn and never makes a generation work.
// `settle` is the settle state of the whole generation a compaction closed,
// the carried tail included; only a compaction records it, because only the
// transcript knows which nags were shown.
public struct GenerationHead: Hashable, Sendable, Codable {
  public struct SettleBoundary: Hashable, Sendable, Codable {
    public var queueTail: Int64
    public var messageTail: Int64

    public init(queueTail: Int64, messageTail: Int64) {
      self.queueTail = queueTail
      self.messageTail = messageTail
    }
  }

  public var id: UUID
  public var timestamp: Date
  public var summary: String
  public var snapshot: StateSnapshot
  public var settle: SettleState?
  public var settleBoundary: SettleBoundary?
  public var note: String?

  public init(id: UUID, timestamp: Date, summary: String, snapshot: StateSnapshot, settle: SettleState? = nil, settleBoundary: SettleBoundary? = nil, note: String? = nil) {
    self.id = id
    self.timestamp = timestamp
    self.summary = summary
    self.snapshot = snapshot
    self.settle = settle
    self.settleBoundary = settleBoundary
    self.note = note
  }
}
