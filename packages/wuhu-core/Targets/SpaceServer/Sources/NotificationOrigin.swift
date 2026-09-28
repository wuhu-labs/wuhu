import JSONValue
import SessionDomain
import SpaceCore

enum NotificationOrigin: Hashable, Sendable {
  case message(sender: String, box: String?)
  case session(String)
}

extension NotificationOrigin {
  // Names resolve when the notification leaves, not when it is recorded: a
  // session often titles itself after it has already started talking.
  init(_ notification: NotificationRecord, space: Space) async throws {
    let payload = JSONValue.parse(notification.payload)?.object
    switch notification.kind {
    case .conversationMessage:
      let sender = payload?["sender"]?.stringValue ?? ""
      let name = try await displayName(sender, space: space)
      // One inbox spans every group, so a sender from outside the
      // conversation's group shows with theirs, as the CLI inbox prints it.
      let outside = payload?["senderGroup"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
      self = .message(
        sender: outside.map { "\(name) (group \($0))" } ?? name,
        box: try await boxTitle(ConversationID(notification.source), unless: sender, space: space),
      )
    case .childFailed, .requestDeadline, .sessionSettled, .sessionErrored,
         .sessionDisconnected, .contractorDisconnected:
      let session = payload?["sessionID"]?.stringValue ?? notification.source
      self = .session(try await sessionTitle(session, space: space) ?? session)
    }
  }
}

struct NotificationSender: Hashable, Sendable {
  enum Kind: String, Sendable {
    case session
    case user
  }

  let id: String
  let kind: Kind
}

extension NotificationSender {
  init?(_ notification: NotificationRecord, space: Space) async throws {
    let payload = JSONValue.parse(notification.payload)?.object
    switch notification.kind {
    case .conversationMessage:
      guard let sender = payload?["sender"]?.stringValue, !sender.isEmpty else { return nil }
      self.init(id: sender, kind: await senderKind(sender, sessions: space.sessions) == .session ? .session : .user)
    case .childFailed, .requestDeadline, .sessionSettled, .sessionErrored,
         .sessionDisconnected, .contractorDisconnected:
      self.init(id: payload?["sessionID"]?.stringValue ?? notification.source, kind: .session)
    }
  }
}

private func sessionTitle(_ id: String, space: Space) async throws -> String? {
  do {
    let title = try await space.sessions.record(SessionID(id)).title
    return title.isEmpty ? nil : title
  } catch SessionStoreError.unknownSession {
    return nil
  }
}

private func boxTitle(_ id: ConversationID, unless sender: String, space: Space) async throws -> String? {
  let conversation: ConversationRecord
  do {
    conversation = try await space.sessions.conversation(id)
  } catch SessionStoreError.unknownConversation {
    return nil
  }
  guard conversation.kind == .box, let owner = conversation.ownerSession, owner.rawValue != sender else { return nil }
  return try await sessionTitle(owner.rawValue, space: space) ?? owner.rawValue
}

private func displayName(_ principal: String, space: Space) async throws -> String {
  if let title = try await sessionTitle(principal, space: space) { return title }
  let profile = try await space.userProfile(principal: principal)
  return profile?.displayName.flatMap { $0.isEmpty ? nil : $0 } ?? profile?.handle ?? principal
}
