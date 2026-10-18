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

  var audience: Audience
  var people: [String]
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
  let notified = snapshot.people.filter { $0 != message.sender.id }
  if message.senderSession == nil {
    let others = keys.filter { snapshot.sessions[$0]?.kind != .task }
    if let task = keys.first, others.isEmpty, notified.isEmpty {
      throw SessionStoreError.taskTakesNoHumanInput(task.rawValue)
    }
    keys = others
  }
  return (keys, notified)
}

enum MentionScanner {
  static func candidates(in text: String) -> [String] {
    text.matches(of: /(?:^|[^A-Za-z0-9_-])@([A-Za-z0-9_-]*-[A-Za-z0-9_-]*)/).map { String($0.1) }
  }
}
