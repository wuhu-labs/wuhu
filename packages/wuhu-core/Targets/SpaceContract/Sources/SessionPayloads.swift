import Contract
import JSONValue

// The wire meaning of an absent identity field: the space owner principal.
public let ownerIdentity: String = "owner"

// Every provider runs in the kernel. kind may come from the
// template; without either a human's request is refused. From a session's
// exec it creates that session's child the way create_session does: kind
// defaults to task, and topLevel (agents only) creates it with no parent.
// group places a top-level agent: default the caller's (acting) group, and it
// must be one that group reads. From a session, `message` is the brief: with
// expectsReply it opens a request on the new child (stallSeconds belongs to
// that request), without it is a DM from the creator. `request` carries that
// request's terms; with a key, a create whose key is taken creates nothing and
// answers the session that holds it, `existing` true.
@Contract
public struct SessionCreateInput: Codable, Equatable, Sendable {
  public let title: String
  public let kind: SessionKindPayload?
  public let tags: [String]?
  public let executor: String?
  public let provider: String?
  public let model: String?
  public let modelGroup: String?
  public let effort: String?
  public let template: String?
  public let identity: String?
  public let topLevel: Bool?
  public let group: String?
  public let message: String?
  public let expectsReply: Bool?
  public let stallSeconds: Double?
  public let request: RequestTermsInput?
}

// A request's row terms. kind defaults to "task"; key is unique per group and
// kind; schema is a JSON Schema a final report's content must satisfy as JSON;
// fields is a JSON object kept on the row.
@Contract
public struct RequestTermsInput: Codable, Equatable, Sendable {
  public let kind: String?
  public let key: String?
  public let schema: JSONValue?
  public let fields: JSONValue?
}

// A session's exec opening a request on one of that session's tasks, as the
// request tool does, with the same terms flat on the body.
@Contract
public struct SessionRequestInput: Codable, Equatable, Sendable {
  public let message: String
  public let deadlineSeconds: Double?
  public let stallSeconds: Double?
  public let kind: String?
  public let key: String?
  public let schema: JSONValue?
  public let fields: JSONValue?
}

// `deadline` is the request's deadline as unix seconds, when it has one.
// `existing` is true when the key was taken: the answer names the request that
// holds it, and nothing was posted.
@Contract
public struct SessionRequestOutput: Codable, Equatable, Sendable {
  public let requestId: String
  public let task: String
  public let conversationId: String
  public let deadline: Double?
  public let existing: Bool?
}

// A session answering a request open on it: progress keeps it open, final
// closes it.
@Contract
public struct RequestReportInput: Codable, Equatable, Sendable {
  public let kind: MessageKindPayload
  public let content: String
}

@Contract
public struct RequestReportOutput: Codable, Equatable, Sendable {
  public let messageId: String
  public let conversationId: String
}

// A session arming one durable slot of its own: exactly one of observe and
// timer. The slot's id is derived from the tool call the request runs for, so
// arming it again under the same call re-arms the same slot.
@Contract
public struct SubscriptionInput: Codable, Equatable, Sendable {
  public let observe: SubscriptionObserveInput?
  public let timer: SubscriptionTimerInput?
  public let handler: String?
}

@Contract
public struct SubscriptionObserveInput: Codable, Equatable, Sendable {
  public let sql: String
  public let throttleSeconds: Double?
}

// One of inSeconds (fire once) and cron (fire repeatedly, five UTC fields).
@Contract
public struct SubscriptionTimerInput: Codable, Equatable, Sendable {
  public let message: String
  public let inSeconds: Double?
  public let cron: String?
}

@Contract
public enum SubscriptionKindPayload: String, Codable, Equatable, Sendable {
  case observe
  case timer
}

// A timer carries its schedule: fireAt (unix seconds) for a one-shot, cron
// for a repeating one.
@Contract
public struct SubscriptionOutput: Codable, Equatable, Sendable {
  public let id: String
  public let kind: SubscriptionKindPayload
  public let fireAt: Double?
  public let cron: String?
}

@Contract
public struct SessionTemplateDescriptor: Codable, Equatable, Sendable {
  public let name: String
  public let kind: SessionKindPayload?
  public let provider: String?
  public let model: String?
  public let modelGroup: String?
  public let effort: String?
  public let description: String?
}

@Contract
public struct SessionTemplatesOutput: Codable, Equatable, Sendable {
  public let templates: [SessionTemplateDescriptor]
}

@Contract
public struct SessionHomeSkill: Codable, Equatable, Sendable {
  public let name: String
  public let description: String
  public let path: String
}

// What the session sees: `chain` is every AGENTS.md that resolves for it, in
// injection order; `home` is its own directory whether or not it exists yet.
@Contract
public struct SessionHomeOutput: Codable, Equatable, Sendable {
  public let home: String
  public let chain: [String]
  public let skills: [SessionHomeSkill]
}

// requestId is the request a session's create opened with expectsReply;
// member is the model group member the new session was routed to.
@Contract
public struct SessionCreateOutput: Codable, Equatable, Sendable {
  public let id: String
  public let executor: String
  public let model: String?
  public let provider: String?
  public let modelGroup: String?
  public let effort: String?
  public let kind: SessionKindPayload
  public let parent: String?
  public let title: String
  public let requestId: String?
  public let member: String?
  public let existing: Bool?
}

@Contract
public enum SessionKindPayload: String, Codable, Equatable, Sendable {
  case agent
  case task
}

@Contract
public enum MessageKindPayload: String, Codable, Equatable, Sendable {
  case message
  case request
  case progress
  case final
}

@Contract
public enum ConversationKindPayload: String, Codable, Equatable, Sendable {
  case users
  case box
  case dmUser = "dm_user"
  case dmSession = "dm_session"
}

@Contract
public enum SessionContextSource: String, Codable, Equatable, Sendable {
  case estimate
  case reported
}

@Contract
public struct SessionContext: Codable, Equatable, Sendable {
  public let usedTokens: Int
  public let maxTokens: Int
  public let percentage: Double
  public let updatedAt: Double?
  public let source: SessionContextSource
}

@Contract
public struct SessionContextOutput: Codable, Equatable, Sendable {
  public let context: SessionContext?
}

@Contract
public struct SessionArchiveInput: Codable, Equatable, Sendable {
  public let force: Bool?
}

@Contract
public struct SessionCompactInput: Codable, Equatable, Sendable {
  public let instructions: String?
}

@Contract
public struct SessionTitleInput: Codable, Equatable, Sendable {
  public let title: String
}

// The title as stored: trimmed to one line.
@Contract
public struct SessionTitleOutput: Codable, Equatable, Sendable {
  public let title: String
}

// Replaces the whole tag list; an empty list clears it.
@Contract
public struct SessionTagsInput: Codable, Equatable, Sendable {
  public let tags: [String]
}

// Omitted target fields keep the requested target. An explicit modelGroup or
// provider/model replaces the target as a whole; effort can change independently.
@Contract
public struct SessionRestartInput: Codable, Equatable, Sendable {
  public let executor: String?
  public let provider: String?
  public let model: String?
  public let modelGroup: String?
  public let effort: String?
  public let message: String?
  public let identity: String?
  public let timezone: String?
  public let viewing: String?
}

@Contract
public struct SessionRestartOutput: Codable, Equatable, Sendable {
  public let id: String
  public let generation: Int
  public let executor: String
  public let model: String?
  public let provider: String?
  public let modelGroup: String?
  public let effort: String?
  public let queued: Int?
}

// Posted as JSON, `attachments` names files already in the space. Posted as
// multipart/form-data, this is the part named `message` and every part named
// `file` is uploaded as one more attachment.
@Contract
public struct ConversationPostInput: Codable, Equatable, Sendable {
  public let message: String
  public let conversation: String?
  public let session: String?
  public let user: String?
  public let replyTarget: String?
  public let identity: String?
  public let timezone: String?
  public let attachments: [String]?
  public let viewing: String?
}

@Contract
public struct ConversationPostOutput: Codable, Equatable, Sendable {
  public let messageId: String
  public let conversationId: String
  public let n: Int
  public let delivered: [String]
}

@Contract
public enum AttachmentKindPayload: String, Codable, Equatable, Hashable, Sendable {
  case image
  case file
}

// Only images posted before files could be attached have no `size`.
@Contract
public struct AttachmentPayload: Codable, Equatable, Hashable, Sendable {
  public let kind: AttachmentKindPayload
  public let path: String
  public let mimeType: String
  public let size: Int?
}

// A server built before files could be attached sends each attachment as the
// bare path of an image; the app reads either shape.
extension AttachmentPayload {
  private enum Field: String, CodingKey {
    case kind
    case path
    case mimeType
    case size
  }

  public init(from decoder: any Decoder) throws {
    if let path = try? decoder.singleValueContainer().decode(String.self) {
      self.init(kind: .image, path: path, mimeType: ImageMedia.mimeType(ofPath: path) ?? MediaType.of(path: path), size: nil)
      return
    }
    let container = try decoder.container(keyedBy: Field.self)
    self.init(
      kind: try container.decode(AttachmentKindPayload.self, forKey: .kind),
      path: try container.decode(String.self, forKey: .path),
      mimeType: try container.decode(String.self, forKey: .mimeType),
      size: try container.decodeIfPresent(Int.self, forKey: .size),
    )
  }
}

@Contract
public struct ConversationMessagePayload: Codable, Equatable, Sendable {
  public let n: Int
  public let messageId: String
  public let conversationId: String
  public let kind: MessageKindPayload
  public let requestId: String?
  public let replyTarget: String?
  public let sender: String
  public let senderHandle: String?
  public let senderKind: SenderKind?
  public let senderTimezone: String
  public let senderSession: String?
  /// The group the message was posted from; absent from servers before groups.
  public let senderGroup: String?
  public let text: String
  public let attachments: [AttachmentPayload]?
  public let createdAt: Double
}

@Contract
public struct ConversationReadOutput: Codable, Equatable, Sendable {
  public let messages: [ConversationMessagePayload]
}

@Contract
public struct ConversationMemberPayload: Codable, Equatable, Sendable {
  public let member: String
  public let memberHandle: String?
  public let kind: String
}

@Contract
public struct ConversationPayload: Codable, Equatable, Sendable {
  public let title: String?
  public let id: String
  public let kind: ConversationKindPayload
  public let ownerSession: String?
  public let members: [ConversationMemberPayload]
  public let windowMessages: Int
  public let windowSeconds: Int
  public let lastMessageN: Int?
  public let lastMessageAt: Double?
}

@Contract
public struct ConversationsOutput: Codable, Equatable, Sendable {
  public let conversations: [ConversationPayload]
}

@Contract
public enum SenderKind: String, Codable, Equatable, Sendable {
  case user
  case session
}

@Contract
public struct ConversationCreateInput: Codable, Equatable, Sendable {
  public let title: String?
  public let members: [String]
  public let identity: String?
}

@Contract
public enum SessionNotificationKind: String, Codable, Equatable, Sendable {
  case conversationMessage = "conversation_message"
  case childFailed = "child_failed"
  case requestDeadline = "request_deadline"
  case sessionSettled = "session_settled"
  case sessionErrored = "session_errored"
  // History only: the removed contractor executor raised these two.
  case sessionDisconnected = "session_disconnected"
  case contractorDisconnected = "contractor_disconnected"
}

@Contract
public struct NotificationPayload: Codable, Equatable, Sendable {
  public let n: Int
  public let recipient: String
  public let source: String
  public let kind: SessionNotificationKind
  public let payload: JSONValue
  public let createdAt: Double
  /// The group the notification belongs to; absent from servers before groups.
  /// A person's inbox spans every group, so each row says which.
  public let group: String?
}

@Contract
public struct NotificationsOutput: Codable, Equatable, Sendable {
  public let notifications: [NotificationPayload]
}

@Contract
public struct WatermarkInput: Codable, Equatable, Sendable {
  public let source: String
  public let identity: String?
}

@Contract
public struct WatermarkOutput: Codable, Equatable, Sendable {
  public let lastReadN: Int
}

@Contract
public struct WebPushConfigOutput: Codable, Equatable, Sendable {
  public let applicationServerKey: String
}

@Contract
public struct WebPushSubscriptionInput: Codable, Equatable, Sendable {
  public let endpoint: String
  public let p256dh: String
  public let auth: String
  public let applicationServerKey: String
  public let expirationTime: Double?
}

@Contract
public struct WebPushSubscriptionDeleteInput: Codable, Equatable, Sendable {
  public let endpoint: String
}

// A grant is what a device hands a space after pairing with the push gateway:
// an opaque id the gateway resolves to a real APNs token, and a bearer token
// that can push to that device. The gateway authenticates the token, not the
// holder — keeping a grant to one space is the device's doing, not something
// the relay enforces. The space never sees the device token, and revoking the
// grant at the gateway is what stops delivery; the space learns about it from
// a 410 on its next push.
@Contract
public struct PushRelayGrantInput: Codable, Equatable, Sendable {
  public let endpoint: String
  public let grant: String
  public let token: String
}

@Contract
public struct PushRelayGrantDeleteInput: Codable, Equatable, Sendable {
  public let grant: String
}

@Contract
public struct TranscriptHistoryEntryPayload: Codable, Equatable, Sendable {
  public let position: Int
  public let item: JSONValue
}

@Contract
public struct TranscriptHistoryOutput: Codable, Equatable, Sendable {
  public let historyEpoch: String?
  public let generation: Int
  public let entries: [TranscriptHistoryEntryPayload]
  public let origins: [TranscriptHistoryEntryPayload]
  public let before: Int?
  public let hasEarlier: Bool
  public let headPosition: Int?
}

@Contract
public struct ConversationHistoryOutput: Codable, Equatable, Sendable {
  public let messages: [ConversationMessagePayload]
  public let before: Int?
  public let hasEarlier: Bool
  public let headPosition: Int?
}

@Contract
public struct TranscriptReadOutput: Codable, Equatable, Sendable {
  public let generation: Int
  public let items: [JSONValue]
}

// ref is an opaque, short-lived per-item handle minted by the server; it dies
// with the next compaction.
@Contract
public struct SessionLogItem: Codable, Equatable, Sendable {
  public let ref: String
  public let receivedAt: Double?
  public let emittedAt: Double?
  public let item: JSONValue
}

@Contract
public struct SessionLogOutput: Codable, Equatable, Sendable {
  public let context: SessionContext?
  public let items: [SessionLogItem]
}

@Contract
public struct SessionEntryOutput: Codable, Equatable, Sendable {
  public let item: SessionLogItem
}

@Contract
public enum SessionStreamEvent: Codable, Equatable, Sendable {
  case reset(generation: Int)
  case item(generation: Int, position: Int, item: JSONValue)
  case started(attemptId: String)
  case delta(attemptId: String, text: String)
  case cancelled(attemptId: String, reason: String)
  case materialized(attemptId: String, entryId: String)
}

@Contract
public struct ChannelMembersInput: Codable, Equatable, Sendable {
  public let people: [String]
}

@Contract
public struct ChannelRenameInput: Codable, Equatable, Sendable {
  public let title: String?
}

@Contract
public struct SessionModelRouteOutput: Codable, Equatable, Sendable {
  public let requestedTarget: JSONValue
  public let activeProvider: String?
  public let activeModel: String?
  public let route: JSONValue?
  public let decisions: JSONValue?
}
