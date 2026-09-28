import Foundation
import struct SpaceContract.PixelSize

public struct ToolResultItem: Hashable, Sendable, Codable {
  public enum Provenance: Hashable, Sendable, Codable {
    case toolCall(ToolCallID)
    case compactionReestablishment
  }

  public var id: UUID
  public var timestamp: Date
  public var provenance: Provenance
  public var payload: ToolResultPayload

  public init(id: UUID, timestamp: Date, provenance: Provenance, payload: ToolResultPayload) {
    self.id = id
    self.timestamp = timestamp
    self.provenance = provenance
    self.payload = payload
  }
}

public enum ToolResultPayload: Hashable, Sendable, Codable {
  case read(ReadResult)
  case write(WriteResult)
  case edit(EditResult)
  case grep(GrepResult)
  case find(FindResult)
  case exec(ExecResult)
  case mount(MountResult)
  case machines(MachinesResult)
  case templates(TemplatesResult)
  case observe(ObserveResult)
  case timer(TimerResult)
  case cancelObservation(CancelObservationResult)
  case cancelTimer(CancelTimerResult)
  case query(QueryResult)
  case sendMessage(SendMessageResult)
  case request(RequestResult)
  case report(ReportResult)
  case createSession(CreateSessionResult)
  case setTitle(SetTitleResult)
  case manipulateUI(ManipulateUIResult)
  case compact(CompactResult)
  case claudeCode(ClaudeCodeToolResult)
  case script(ScriptResult)
  case failure(ToolFailure)
}

public struct ClaudeCodeToolResult: Hashable, Sendable, Codable {
  public var text: String
  public var isError: Bool

  public init(text: String, isError: Bool) {
    self.text = text
    self.isError = isError
  }
}

// The compact tool's own closing result; it lives in the old generation only
// and is never rendered to a model.
public struct CompactResult: Hashable, Sendable, Codable {
  public var summary: String

  public init(summary: String) {
    self.summary = summary
  }
}

public enum FileRevision: Hashable, Sendable, Codable {
  case journal(Int64)
  case mtime(Date)
}

public struct ScopeContext: Hashable, Sendable, Codable {
  public var folders: [String: String?]
  public var text: String

  public init(folders: [String: String?], text: String) {
    self.folders = folders
    self.text = text
  }

  public func notice(id: UUID, at timestamp: Date) -> SystemNotification {
    SystemNotification(
      id: id, timestamp: timestamp, kind: .context, subscriptionID: .context, folderRoots: folders,
      content: .init(text: text),
    )
  }

  public func rendered(at timestamp: Date) -> String? {
    guard !text.isEmpty else { return nil }
    return MessageHeader.systemNotice(source: .context, at: timestamp).render() + "\n\n" + text
  }
}

public struct ReadResult: Hashable, Sendable, Codable {
  public var path: String
  public var revision: FileRevision
  public var content: String
  public var image: ImageContent?

  public init(path: String, revision: FileRevision, content: String, image: ImageContent? = nil) {
    self.path = path
    self.revision = revision
    self.content = content
    self.image = image
  }
}

public struct ImageContent: Hashable, Sendable {
  public enum Source: Hashable, Sendable {
    case inline(Data)
    case blob(String)
  }

  public var mimeType: String
  public var byteCount: Int
  public var source: Source
  // Absent on rows written before sizes were recorded.
  public var pixels: PixelSize?

  public init(mimeType: String, source: Source, byteCount: Int, pixels: PixelSize? = nil) {
    self.mimeType = mimeType
    self.source = source
    self.byteCount = byteCount
    self.pixels = pixels
  }

  public init(mimeType: String, data: Data) {
    self.init(mimeType: mimeType, source: .inline(data), byteCount: data.count)
  }
}

extension ImageContent: Codable {
  enum CodingKeys: String, CodingKey {
    case mimeType
    case data
    case hash
    case byteCount
    case width
    case height
  }

  // Rows written before images moved to the blob store carry `data`; the
  // absence of `hash` is what identifies them, so they keep decoding.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mimeType = try container.decode(String.self, forKey: .mimeType)
    if let hash = try container.decodeIfPresent(String.self, forKey: .hash) {
      source = .blob(hash)
      byteCount = try container.decode(Int.self, forKey: .byteCount)
    } else {
      let data = try container.decode(Data.self, forKey: .data)
      source = .inline(data)
      byteCount = data.count
    }
    pixels = try PixelSize(container, width: .width, height: .height)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(mimeType, forKey: .mimeType)
    switch source {
    case let .inline(data):
      try container.encode(data, forKey: .data)
    case let .blob(hash):
      try container.encode(hash, forKey: .hash)
      try container.encode(byteCount, forKey: .byteCount)
    }
    try container.encodeIfPresent(pixels?.width, forKey: .width)
    try container.encodeIfPresent(pixels?.height, forKey: .height)
  }
}

public struct WriteResult: Hashable, Sendable, Codable {
  public var path: String
  public var revision: FileRevision

  public init(path: String, revision: FileRevision) {
    self.path = path
    self.revision = revision
  }
}

public struct EditResult: Hashable, Sendable, Codable {
  public var path: String
  public var revision: FileRevision

  public init(path: String, revision: FileRevision) {
    self.path = path
    self.revision = revision
  }
}

public struct GrepResult: Hashable, Sendable, Codable {
  public var output: String

  public init(output: String) {
    self.output = output
  }
}

public struct ScriptResult: Hashable, Sendable, Codable {
  public var output: String

  public init(output: String) {
    self.output = output
  }
}

public struct FindResult: Hashable, Sendable, Codable {
  public var output: String

  public init(output: String) {
    self.output = output
  }
}

public struct ExecResult: Hashable, Sendable, Codable {
  public var output: String
  public var exitCode: Int32
  // The machine reaped the process past the rejoin deadline; output is the
  // buffered stream to termination, not a live run.
  public var reaped: Bool

  public init(output: String, exitCode: Int32, reaped: Bool = false) {
    self.output = output
    self.exitCode = exitCode
    self.reaped = reaped
  }
}

public struct Mount: Hashable, Sendable, Codable {
  public var location: String

  public init(location: String) {
    self.location = location
  }
}

// Nothing produces this any more: transcripts written while the mount tool
// existed still hold its results, and they must keep decoding and rendering.
public struct MountResult: Hashable, Sendable, Codable {
  public var mount: Mount
  public var contextVersion: Int
  public var contextEmission: String?

  public init(mount: Mount, contextVersion: Int, contextEmission: String?) {
    self.mount = mount
    self.contextVersion = contextVersion
    self.contextEmission = contextEmission
  }
}

public struct MachineListing: Hashable, Sendable, Codable {
  public var id: String
  public var name: String?
  public var attached: Bool

  public init(id: String, name: String?, attached: Bool) {
    self.id = id
    self.name = name
    self.attached = attached
  }
}

public struct MachinesResult: Hashable, Sendable, Codable {
  public var machines: [MachineListing]

  public init(machines: [MachineListing]) {
    self.machines = machines
  }

  public var rendered: String {
    guard !machines.isEmpty else { return "no machines are enrolled in this space" }
    return machines.map { machine in
      let state = machine.attached ? "attached" : "detached"
      return (machine.name.map { "\($0) " } ?? "") + "\(machine.id) \(state)"
    }.joined(separator: "\n")
  }
}

public struct TemplateListing: Hashable, Sendable, Codable {
  public var name: String
  public var kind: String?
  public var provider: String?
  public var model: String?
  public var effort: String?
  public var description: String?

  public init(name: String, kind: String?, provider: String?, model: String?, effort: String?, description: String?) {
    self.name = name
    self.kind = kind
    self.provider = provider
    self.model = model
    self.effort = effort
    self.description = description
  }
}

public struct TemplatesResult: Hashable, Sendable, Codable {
  public var templates: [TemplateListing]

  public init(templates: [TemplateListing]) {
    self.templates = templates
  }

  public var rendered: String {
    guard !templates.isEmpty else { return "this space has no session templates (/templates/<name>/template.json)" }
    return templates.map { template in
      let spec = [template.kind, template.provider, template.model, template.effort].compactMap(\.self)
      return "- \(template.name) [\(spec.joined(separator: " "))]" + (template.description.map { " — \($0)" } ?? "")
    }.joined(separator: "\n")
  }
}

public struct ObserveResult: Hashable, Sendable, Codable {
  public var subscriptionID: SubscriptionID
  public var sql: String

  public init(subscriptionID: SubscriptionID, sql: String) {
    self.subscriptionID = subscriptionID
    self.sql = sql
  }
}

public enum TimerSchedule: Hashable, Sendable, Codable {
  case oneShot(Date)
  case cron(String)
}

public struct TimerResult: Hashable, Sendable, Codable {
  public var subscriptionID: SubscriptionID
  public var schedule: TimerSchedule
  public var message: String

  public init(subscriptionID: SubscriptionID, schedule: TimerSchedule, message: String) {
    self.subscriptionID = subscriptionID
    self.schedule = schedule
    self.message = message
  }
}

public struct CancelObservationResult: Hashable, Sendable, Codable {
  public var subscriptionID: SubscriptionID

  public init(subscriptionID: SubscriptionID) {
    self.subscriptionID = subscriptionID
  }
}

public struct CancelTimerResult: Hashable, Sendable, Codable {
  public var subscriptionID: SubscriptionID

  public init(subscriptionID: SubscriptionID) {
    self.subscriptionID = subscriptionID
  }
}

public struct QueryResult: Hashable, Sendable, Codable {
  public var output: String

  public init(output: String) {
    self.output = output
  }
}

public struct SendMessageResult: Hashable, Sendable, Codable {
  public var messageID: MessageID
  public var conversationID: ConversationID
  public var n: Int64
  public var replyTarget: MessageID?

  public init(messageID: MessageID, conversationID: ConversationID, n: Int64, replyTarget: MessageID? = nil) {
    self.messageID = messageID
    self.conversationID = conversationID
    self.n = n
    self.replyTarget = replyTarget
  }
}

public struct RequestResult: Hashable, Sendable, Codable {
  public var requestID: RequestID
  public var task: SessionID
  public var conversationID: ConversationID
  public var deadline: Date?

  public init(requestID: RequestID, task: SessionID, conversationID: ConversationID, deadline: Date? = nil) {
    self.requestID = requestID
    self.task = task
    self.conversationID = conversationID
    self.deadline = deadline
  }
}

public struct ReportResult: Hashable, Sendable, Codable {
  public var messageID: MessageID
  public var requestID: RequestID
  public var conversationID: ConversationID
  public var kind: MessageKind

  public init(messageID: MessageID, requestID: RequestID, conversationID: ConversationID, kind: MessageKind) {
    self.messageID = messageID
    self.requestID = requestID
    self.conversationID = conversationID
    self.kind = kind
  }
}

public struct CreateSessionResult: Hashable, Sendable, Codable {
  public var sessionID: SessionID
  public var title: String
  public var requestID: RequestID?
  // Only on the receipt recorded with the new session: true while its
  // template's files are still owed to its home, so a replay of the same call
  // clones them instead of answering with a half-made session.
  public var cloneOwed: Bool?

  public init(sessionID: SessionID, title: String, requestID: RequestID? = nil, cloneOwed: Bool? = nil) {
    self.sessionID = sessionID
    self.title = title
    self.requestID = requestID
    self.cloneOwed = cloneOwed
  }
}

public struct SetTitleResult: Hashable, Sendable, Codable {
  public var title: String

  public init(title: String) {
    self.title = title
  }
}

public struct ManipulateUIResult: Hashable, Sendable, Codable {
  public var device: String
  public var n: Int64

  public init(device: String, n: Int64) {
    self.device = device
    self.n = n
  }
}

public struct ToolFailure: Hashable, Sendable, Codable {
  public var message: String

  public init(message: String) {
    self.message = message
  }
}
