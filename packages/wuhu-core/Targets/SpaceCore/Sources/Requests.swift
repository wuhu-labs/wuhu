import Foundation
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
  ) async throws -> MessageDelivery {
    let key = task.rawValue
    // A retry of a request that already posted replays it: that request is
    // the open one, not a second.
    let replay = try await message(messageID) != nil
    try await writer.read { db in
      let record = try Sessions.record(key, in: db)
      guard record.parent == parent else { throw SessionStoreError.notTheParent(key) }
      let state = try Sessions.settleState(key, in: db)
      if !replay, let open = state.openRequests.values.first {
        throw SessionStoreError.requestAlreadyOpen(open.id.rawValue)
      }
    }
    let request = RequestID(messageID.rawValue)
    let delivery = try await post(
      .dm(with: key),
      messageID: messageID,
      sender: Sender(id: parent.rawValue, timeZone: TimeZone(identifier: "UTC")!),
      senderSession: parent,
      kind: .request,
      requestID: request,
      deadline: deadline,
      content: MessageContent(text: text),
    )
    if let deadline, !delivery.replayed {
      try await armSubscription(
        parent,
        slot: .init(id: .deadline(request), kind: .requestDeadline(request: request, task: task)),
        nextFireAt: deadline,
      )
    }
    return delivery
  }

  public func report(
    _ task: SessionID,
    request: RequestID,
    kind: MessageKind,
    messageID: MessageID,
    text: String,
  ) async throws -> MessageDelivery {
    let key = task.rawValue
    let parent = try await writer.read { db in
      let record = try Sessions.record(key, in: db)
      guard let parent = record.parent else { throw SessionStoreError.noParent(key) }
      let state = try Sessions.settleState(key, in: db)
      guard state.openRequests[request] != nil else {
        throw SessionStoreError.unknownRequest(request.rawValue)
      }
      return parent
    }
    let delivery = try await post(
      .dm(with: parent.rawValue),
      messageID: messageID,
      sender: Sender(id: key, timeZone: TimeZone(identifier: "UTC")!),
      senderSession: task,
      kind: kind,
      requestID: request,
      content: MessageContent(text: text),
    )
    if kind == .final {
      try await cancelSubscription(parent, subscriptionID: .deadline(request))
    }
    return delivery
  }

  public func recordRequestDeadline(
    parent: SessionID,
    task: SessionID,
    request: RequestID,
    deadline: Date,
  ) async throws {
    let now = SQLiteDateFormat.string(from: dateGen.now)
    try await writer.write { db in
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
