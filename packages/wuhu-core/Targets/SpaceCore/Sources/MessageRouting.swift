#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain

struct RoutingSnapshot {
  enum Audience: Sendable {
    case box(SessionID, messages: Int, seconds: Int)
    case channel(messages: Int, seconds: Int)
    case direct([SessionID])
  }

  enum ReplySender: Sendable {
    case unaddressed
    case session(SessionID)
  }

  typealias Session = (kind: SessionKind, reachable: Bool)
  typealias RecentSender = (session: SessionID, lastPostedAt: Date, messagesSince: Int)
  typealias Write = (person: String, n: Int64, at: Date)

  static let boxNotificationSeconds: TimeInterval = 86400

  var audience: Audience
  var people: [String]
  /// A box's person posts before this one, each person's latest: the box's
  /// latest one and those inside the notification window. Empty elsewhere.
  var writes: [Write] = []
  /// A person's own post, not a session's or a group observer's.
  var postedByPerson = false
  var sessions: [SessionID: Session]
  var replySender: ReplySender
  var recentSenders: [RecentSender]
}

func recipients(snapshot: RoutingSnapshot, message: MessageRecord, now: Date) throws -> (woken: [SessionID], notified: [String]) {
  var keys: [SessionID] = []
  switch snapshot.audience {
  case let .box(owner, _, _): keys.append(owner)
  case .channel: break
  case let .direct(members): keys += members
  }
  var addressed = MentionScanner.candidates(in: message.content.text).map { SessionID($0) }
  if case let .session(parent) = snapshot.replySender { addressed.append(parent) }
  keys += addressed.filter { snapshot.sessions[$0]?.reachable == true }

  switch snapshot.audience {
  case let .box(_, count, seconds), let .channel(count, seconds):
    let horizon = now.addingTimeInterval(-Double(seconds))
    keys += snapshot.recentSenders.filter {
      snapshot.sessions[$0.session]?.kind == .agent && $0.messagesSince < count && $0.lastPostedAt >= horizon
    }.map(\.session)
  case .direct: break
  }

  var seen: Set<SessionID> = []
  keys = keys.filter { $0 != message.senderSession && seen.insert($0).inserted }
  let notified = notifiable(snapshot, message: message, now: now).filter { $0 != message.sender.id }
  if message.senderSession == nil {
    let others = keys.filter { snapshot.sessions[$0]?.kind != .task }
    if let task = keys.first, others.isEmpty, notified.isEmpty {
      throw SessionStoreError.taskTakesNoHumanInput(task.rawValue)
    }
    keys = others
  }
  return (keys, notified)
}

private func notifiable(_ snapshot: RoutingSnapshot, message: MessageRecord, now: Date) -> [String] {
  guard case .box = snapshot.audience else { return snapshot.people }
  let latest = snapshot.postedByPerson ? message.sender.id : snapshot.writes.max { $0.n < $1.n }?.person
  let horizon = now.addingTimeInterval(-RoutingSnapshot.boxNotificationSeconds)
  var writers = Set(snapshot.writes.filter { $0.at >= horizon }.map(\.person))
  if let latest { writers.insert(latest) }
  return snapshot.people.filter(writers.contains)
}

enum MentionScanner {
  static func candidates(in text: String) -> [String] {
    text.matches(of: /(?:^|[^A-Za-z0-9_-])@([A-Za-z0-9_-]*-[A-Za-z0-9_-]*)/).map { String($0.1) }
  }
}
