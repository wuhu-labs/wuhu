#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import GRDB
import SessionDomain
import struct SpaceContract.GroupID

extension SessionStore {
  public func openRequest(
    on task: SessionID,
    from parent: SessionID,
    messageID: MessageID,
    text: String,
    deadline: Date?,
    stallSeconds: Double? = nil,
  ) async throws -> MessageDelivery {
    let key = task.rawValue
    try await writer.read { db in
      let record = try Sessions.record(key, in: db)
      guard record.parent == parent else { throw SessionStoreError.notTheParent(key) }
      // A retry of a request that already posted replays it: that request is
      // the open one, not a second.
      let state = try Sessions.settleState(key, in: db)
      if try Conversations.message(id: messageID.rawValue, in: db) == nil, let open = state.openRequests.values.first {
        throw SessionStoreError.requestAlreadyOpen(open.id.rawValue)
      }
    }
    let request = RequestID(messageID.rawValue)
    // The clocks commit with the message: a request that exists has its
    // deadline and stall alert, and a replayed one keeps the ones it got.
    return try await post(
      .dm(with: key),
      messageID: messageID,
      sender: Sender(id: parent.rawValue, timeZone: TimeZone(identifier: "UTC")!),
      senderSession: parent,
      kind: .request,
      requestID: request,
      deadline: deadline,
      content: MessageContent(text: text),
      alongside: { message, db in
        let now = SQLiteDateFormat.string(from: message.createdAt)
        if let deadline {
          try self.armSubscription(
            parent.rawValue,
            slot: .init(id: .deadline(request), kind: .requestDeadline(request: request, task: task)),
            nextFireAt: deadline, marker: nil, now: now, in: db,
          )
        }
        if let stallSeconds {
          let opened = message.createdAt
          try self.armSubscription(
            parent.rawValue,
            slot: .init(id: .stall(request), kind: .requestStall(.init(request: request, task: task, seconds: stallSeconds, openedAt: opened))),
            nextFireAt: opened.addingTimeInterval(stallSeconds), marker: nil, now: now, in: db,
          )
        }
      },
    )
  }

  public func report(
    _ task: SessionID,
    request: RequestID,
    kind: MessageKind,
    messageID: MessageID,
    text: String,
  ) async throws -> MessageDelivery {
    let key = task.rawValue
    // A retried report is the first one again: its message stands, and what
    // that message closed stays closed.
    if let posted = try await message(messageID) {
      return MessageDelivery(message: posted, enqueued: [], replayed: true)
    }
    let parent = try await writer.read { db in
      let record = try Sessions.record(key, in: db)
      guard let parent = record.parent else { throw SessionStoreError.noParent(key) }
      let state = try Sessions.settleState(key, in: db)
      guard state.openRequests[request] != nil else {
        throw SessionStoreError.unknownRequest(request.rawValue)
      }
      return parent
    }
    // A final ends the request's clocks in the write that posts it.
    var closing: (@Sendable (MessageRecord, Database) throws -> Void)?
    if kind == .final {
      closing = { _, db in
        try Self.deleteSubscription(parent.rawValue, .deadline(request), in: db)
        try Self.deleteSubscription(parent.rawValue, .stall(request), in: db)
      }
    }
    return try await post(
      .dm(with: parent.rawValue),
      messageID: messageID,
      sender: Sender(id: key, timeZone: TimeZone(identifier: "UTC")!),
      senderSession: task,
      kind: kind,
      requestID: request,
      content: MessageContent(text: text),
      alongside: closing,
    )
  }

  public func recordRequestDeadline(
    parent: SessionID,
    task: SessionID,
    request: RequestID,
    deadline: Date,
  ) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
      try recordRequestDeadline(parent: parent, task: task, request: request, deadline: deadline, now: now, in: db)
    }
  }

  func recordRequestDeadline(
    parent: SessionID,
    task: SessionID,
    request: RequestID,
    deadline: Date,
    now: String,
    in db: Database,
  ) throws {
    try Notifications.append(
      recipient: Notifications.ownerRecipient,
      source: parent.rawValue,
      group: try Sessions.group(of: parent.rawValue, in: db),
      kind: .requestDeadline,
      payload: try Sessions.encode(Notifications.RequestDeadlinePayload(
        sessionID: task.rawValue,
        parent: parent.rawValue,
        requestID: request.rawValue,
        deadlineAt: deadline.timeIntervalSince1970,
      )),
      now: now,
      in: db,
    )
  }

  // An errored or killed child with an open request tells its parent so;
  // fabricating a final on its behalf is the one thing that must never happen.
  func notifyParentOfFailure(_ key: String, error: String, now: String, in db: Database) throws -> SessionID? {
    let record = try Sessions.record(key, in: db)
    guard let parent = record.parent else { return nil }
    let state = try Sessions.settleState(key, in: db)
    guard let open = state.openRequests.values.sorted(by: { $0.openedAt < $1.openedAt }).first else { return nil }
    let nowDate = try SQLiteDateFormat.date(from: now)
    let notification = SystemNotification(
      id: UUID.deterministic("child-failed", key, open.id.rawValue),
      timestamp: nowDate,
      kind: .childFailed,
      subscriptionID: .deadline(open.id),
      requestID: open.id,
      content: .init(text: "session \(key) failed with an open request \(open.id.rawValue) and sent no final report: \(error)"),
    )
    let enqueued = (try? Sessions.enqueue(parent.rawValue, input: .notification(notification), nowDate: nowDate, in: db)) != nil
    try Notifications.append(
      recipient: Notifications.ownerRecipient,
      source: parent.rawValue,
      group: try Sessions.group(of: parent.rawValue, in: db),
      kind: .childFailed,
      payload: try Sessions.encode(Notifications.ChildFailedPayload(
        sessionID: key, parent: parent.rawValue, requestID: open.id.rawValue, error: error,
      )),
      now: now,
      in: db,
    )
    return enqueued ? parent : nil
  }
}
