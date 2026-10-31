import DeterministicDependencies
import Foundation
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct MessageRoutingTests {
  struct Case: Sendable {
    var name: String
    var audience: RoutingSnapshot.Audience = .channel(messages: 10, seconds: 900)
    var text = ""
    var sender: SessionID? = nil
    var reply: RoutingSnapshot.ReplySender = .unaddressed
    var recent: [RoutingSnapshot.RecentSender] = []
    var people: [String] = []
    var writes: [RoutingSnapshot.Write] = []
    var postedByPerson = false
    var expected: [SessionID] = []
    var notified: [String] = []
    var refused = false
  }

  private static let now = Date(timeIntervalSince1970: 1_000_000)
  private static let owner = SessionID("box-owner")
  private static let visitor = SessionID("box-visitor")
  private static let task = SessionID("child-task")
  private static let unreachable = SessionID("other-agent")

  private static func recent(_ session: SessionID = visitor, count: Int = 0, age: Double = 0) -> RoutingSnapshot.RecentSender {
    (session: session, lastPostedAt: now.addingTimeInterval(-age), messagesSince: count)
  }

  private static func write(_ person: String, _ n: Int64, age: Double) -> RoutingSnapshot.Write {
    (person: person, n: n, at: now.addingTimeInterval(-age))
  }

  private static let box = RoutingSnapshot.Audience.box(owner, messages: 10, seconds: 900)
  private static let day = RoutingSnapshot.boxNotificationSeconds

  static let cases: [Case] = [
    .init(name: "box owner", audience: .box(owner, messages: 10, seconds: 900), expected: [owner]),
    .init(name: "DM members and no attention", audience: .direct([owner, visitor]), sender: owner, recent: [recent(unreachable)], expected: [visitor]),
    .init(name: "mentions require an existing reachable session", text: "@box-visitor @other-agent @missing-agent", expected: [visitor]),
    .init(name: "mention tokens", text: "mail@box-visitor.example @box-visitor-extra @plain", expected: []),
    .init(name: "reply to session", reply: .session(visitor), expected: [visitor]),
    .init(name: "reply reachability", reply: .session(unreachable)),
    .init(name: "deduplicate all sources", audience: .box(owner, messages: 10, seconds: 900), text: "@box-owner @box-visitor @box-visitor", reply: .session(visitor), recent: [recent(visitor)], expected: [owner, visitor]),
    .init(name: "never wake sender", text: "@box-visitor", sender: visitor, reply: .session(visitor), recent: [recent(visitor)]),
    .init(name: "attention follows session-id order, not recency", recent: [recent(owner, count: 1), recent(visitor)], expected: [owner, visitor]),
    .init(name: "window inside both bounds", recent: [recent(count: 9, age: 899)], expected: [visitor]),
    .init(name: "time boundary inclusive", recent: [recent(age: 900)], expected: [visitor]),
    .init(name: "count boundary exclusive", recent: [recent(count: 10)]),
    .init(name: "time expires before count", recent: [recent(age: 901)]),
    .init(name: "tasks never attentive", sender: owner, recent: [recent(task)]),
    .init(name: "session can address task", text: "@child-task", sender: owner, expected: [task]),
    .init(name: "human task-only post refused", text: "@child-task", refused: true),
    .init(name: "human task-only reply refused", reply: .session(task), refused: true),
    .init(name: "human task mention spared with agent", audience: .box(owner, messages: 10, seconds: 900), text: "@child-task", expected: [owner]),
    .init(name: "human task mention spared with person", text: "@child-task", people: ["reader"], notified: ["reader"]),
    .init(name: "notify people except sender", people: ["writer", "reader"], notified: ["reader"]),
    .init(name: "sender membership does not spare task-only post", text: "@child-task", people: ["writer"], refused: true),
    .init(name: "box notifies its latest writer, however long ago", audience: box, sender: owner, people: ["hazel"], writes: [write("hazel", 1, age: 7 * day)], notified: ["hazel"]),
    .init(name: "equal timestamps: the later position is the latest writer", audience: box, sender: owner, people: ["hazel", "minsheng"], writes: [write("hazel", 2, age: 2 * day), write("minsheng", 1, age: 2 * day)], notified: ["hazel"]),
    .init(name: "a clock that stepped back: the later position is the latest writer", audience: box, sender: owner, people: ["hazel", "minsheng"], writes: [write("hazel", 2, age: 3 * day), write("minsheng", 1, age: 2 * day)], notified: ["hazel"]),
    .init(name: "box notifies a writer exactly 24 h back", audience: box, sender: owner, people: ["minsheng", "hazel"], writes: [write("minsheng", 2, age: 60), write("hazel", 1, age: day)], notified: ["minsheng", "hazel"]),
    .init(name: "box skips a writer just past 24 h", audience: box, sender: owner, people: ["minsheng", "hazel"], writes: [write("minsheng", 2, age: 60), write("hazel", 1, age: day + 1)], notified: ["minsheng"]),
    .init(name: "box skips a member who never wrote", audience: box, sender: owner, people: ["minsheng", "reader"], writes: [write("minsheng", 1, age: 60)], notified: ["minsheng"]),
    .init(name: "a person's post is the latest write: only other recent writers hear it", audience: box, people: ["writer", "hazel", "minsheng"], writes: [write("hazel", 3, age: 2 * day), write("writer", 2, age: 60), write("minsheng", 1, age: 60)], postedByPerson: true, expected: [owner], notified: ["minsheng"]),
    .init(name: "an observer's post is no write: the latest person writer hears it", audience: box, people: ["hazel", "watch@shared"], writes: [write("hazel", 1, age: 2 * day)], expected: [owner], notified: ["hazel"]),
    .init(name: "channel notifies every member, however quiet", people: ["hazel", "reader"], notified: ["hazel", "reader"]),
  ]

  @Test(arguments: cases) func routing(_ test: Case) throws {
    let snapshot = RoutingSnapshot(
      audience: test.audience, people: test.people, writes: test.writes, postedByPerson: test.postedByPerson,
      sessions: [
        Self.owner: (kind: .agent, reachable: true),
        Self.visitor: (kind: .agent, reachable: true),
        Self.task: (kind: .task, reachable: true),
        Self.unreachable: (kind: .agent, reachable: false),
      ],
      replySender: test.reply, recentSenders: test.recent,
    )
    let message = MessageRecord(
      n: 1, id: MessageID("message"), conversation: ConversationID("conversation"),
      sender: Sender(id: "writer", timeZone: .gmt), senderSession: test.sender,
      senderGroup: .shared, replyTarget: nil, kind: .message, requestID: nil, deadline: nil,
      viewing: nil, content: .init(text: test.text), createdAt: Self.now,
    )
    if test.refused {
      #expect(throws: SessionStoreError.taskTakesNoHumanInput(Self.task.rawValue)) {
        try recipients(snapshot: snapshot, message: message, now: Self.now)
      }
    } else {
      let result = try recipients(snapshot: snapshot, message: message, now: Self.now)
      #expect(result.woken == test.expected)
      #expect(result.notified == test.notified)
    }
  }

  @Test(arguments: [
    ("hey @a-b", ["a-b"]), ("mail@a-b", []), ("@a-b@c-d", ["a-b"]),
    ("@a-b@@c-d", ["a-b", "c-d"]), ("x_@a-b", []), ("é@a-b", ["a-b"]),
    ("@a-b\u{301}", ["a-"]), ("@a\u{301}-b", []), ("@a-b🇺🇸@c-d", ["a-b", "c-d"]),
    ("@- @a-- @a-b_", ["-", "a--", "a-b_"]),
    ("@plain @a_b @a1 @A-B", ["A-B"]), ("x@a-b _@c-d 7@e-f -@g-h", []),
    ("@a-b.c @a-b/@c-d", ["a-b", "a-b", "c-d"]), ("@a-bé@c-d", ["a-b", "c-d"]),
  ]) func mentionTokens(_ text: String, expected: [String]) {
    #expect(MentionScanner.candidates(in: text) == expected)
  }
}
