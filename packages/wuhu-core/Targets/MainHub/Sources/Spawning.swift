import SessionDomain

// The operator verbs a session may apply to itself and its descendants, and,
// for archive and unarchive, to a session it created and, as a top-level
// agent, to any session of its group. The session loops live above this
// target, so the server hands them in.
public struct SessionControl: Sendable {
  public enum Verb: String, Sendable, CaseIterable {
    case interrupt
    case resume
    case archive
    case unarchive
  }

  public var perform: @Sendable (Verb, SessionID, Bool) async throws -> Void

  public init(perform: @escaping @Sendable (Verb, SessionID, Bool) async throws -> Void) {
    self.perform = perform
  }
}

// A verb the session loop refused, with the reason a caller can read.
public struct SessionControlRefusal: Error {
  public enum Reason: Sendable {
    case busy
    case other
  }

  public var message: String
  public var reason: Reason

  public init(_ message: String, reason: Reason = .other) {
    self.message = message
    self.reason = reason
  }
}

public struct SpawnOrder: Sendable {
  public var executor: String? = nil
  public var title: String
  public var kind: String?
  public var topLevel = false
  public var group: String?
  public var provider: String?
  public var model: String?
  public var modelGroup: String?
  public var effort: String?
  public var tags: [String]?
  public var template: String?
  public var expectsReply = false
  public var message: String?
  public var stallSeconds: Double?
  public init(
    executor: String? = nil,
    title: String,
    kind: String? = nil,
    topLevel: Bool = false,
    group: String? = nil,
    provider: String? = nil,
    model: String? = nil,
    modelGroup: String? = nil,
    effort: String? = nil,
    tags: [String]? = nil,
    template: String? = nil,
    expectsReply: Bool = false,
    message: String? = nil,
    stallSeconds: Double? = nil,
  ) {
    self.executor = executor; self.title = title; self.kind = kind; self.topLevel = topLevel
    self.group = group; self.provider = provider; self.model = model; self.effort = effort
    self.modelGroup = modelGroup
    self.tags = tags; self.template = template; self.expectsReply = expectsReply; self.message = message
    self.stallSeconds = stallSeconds
  }
}

public struct Spawned: Sendable {
  public var id: SessionID
  public var title: String
  public var requestID: RequestID?
  public var modelGroup: String?
  public var member: String?
  public var provider: String?
  public var model: String?
  // Set when the session exists but cloning its template or handing it the
  // message failed: the caller still learns the id.
  public var unfinished: String?
  public init(id: SessionID, title: String, requestID: RequestID? = nil, unfinished: String? = nil, modelGroup: String? = nil, member: String? = nil, provider: String? = nil, model: String? = nil) {
    self.id = id; self.title = title; self.requestID = requestID; self.unfinished = unfinished
    self.modelGroup = modelGroup; self.member = member; self.provider = provider; self.model = model
  }
}
