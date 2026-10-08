import Foundation
import SessionDomain
import Testing

@Suite struct HeaderRenderingTests {
  @Test(arguments: ["UTC", "Asia/Kolkata", "America/St_Johns", "America/New_York"], [
    -0.125, 1_767_225_600.999,
    1_772_953_199.999, 1_772_953_200.001,
    1_793_512_799.999, 1_793_512_800.001,
  ])
  func timestampsMatchThePreviousFormatter(zone: String, epoch: Double) throws {
    let timeZone = try #require(TimeZone(identifier: zone))
    let date = Date(timeIntervalSince1970: epoch)
    let previous = ISO8601DateFormatter()
    previous.timeZone = timeZone
    previous.formatOptions = [.withInternetDateTime]
    let header = MessageHeader(sender: "alice", timestamp: date, timeZone: timeZone, source: .direct, kind: .message)
    #expect(header.render().contains("<timestamp>\(previous.string(from: date))</timestamp>"))
  }

  @Test(arguments: [
    (1_772_953_199.999, "2026-03-08T01:59:59-05:00"),
    (1_772_953_200.001, "2026-03-08T03:00:00-04:00"),
    (1_793_512_799.999, "2026-11-01T01:59:59-04:00"),
    (1_793_512_800.001, "2026-11-01T01:00:00-05:00"),
  ])
  func daylightSavingTransitionsKeepTheSendersOffset(sample: (Double, String)) throws {
    let timeZone = try #require(TimeZone(identifier: "America/New_York"))
    let header = MessageHeader(sender: "alice", timestamp: Date(timeIntervalSince1970: sample.0), timeZone: timeZone, source: .direct, kind: .message)
    #expect(header.render().contains("<timestamp>\(sample.1)</timestamp>"))
  }

  @Test func `a conversation message header carries the sender's timezone offset and message id`() {
    guard case let .message(message) = Fix.message(id: "m1", sender: "alice") else {
      Issue.record("fixture shape")
      return
    }
    #expect(message.header.render() == """
    <sender>alice</sender>
    <timestamp>2026-01-01T09:00:00+09:00</timestamp>
    <source>conversation/ch1</source>
    <type>message</type>
    <message-id>m1</message-id>
    """)
  }

  @Test func `a reply target renders as its own tag and flips the type`() {
    guard case let .message(message) = Fix.message(id: "m2", sender: "bob", replyTarget: "m1") else {
      Issue.record("fixture shape")
      return
    }
    #expect(message.header.render() == """
    <sender>bob</sender>
    <timestamp>2026-01-01T09:00:00+09:00</timestamp>
    <source>conversation/ch1</source>
    <type>reply</type>
    <message-id>m2</message-id>
    <reply-target>m1</reply-target>
    """)
  }

  @Test func `a request renders its own type`() {
    guard case let .message(message) = Fix.message(id: "m3", kind: .request, request: "m3", sender: "boss") else {
      Issue.record("fixture shape")
      return
    }
    #expect(message.header.render().contains("<type>request</type>"))
  }

  @Test func `system notification header is UTC with the bare subscription id`() {
    guard case let .notification(notification) = Fix.notification(kind: .timer, subscription: "tim-1") else {
      Issue.record("fixture shape")
      return
    }
    #expect(notification.header.render() == """
    <sender>system</sender>
    <timestamp>2026-01-01T00:00:00Z</timestamp>
    <source>tim-1</source>
    <type>timer</type>
    """)
  }

  @Test func `an owed-reply reminder header renders through the same single renderer`() {
    guard case let .notification(notification) = Fix.notification(kind: .owedReply, subscription: "owed.reply") else {
      Issue.record("fixture shape")
      return
    }
    #expect(notification.header.render() == """
    <sender>system</sender>
    <timestamp>2026-01-01T00:00:00Z</timestamp>
    <source>owed.reply</source>
    <type>owed reply</type>
    """)
  }

  @Test func `a known principal renders its handle beside the principal`() {
    guard case let .message(message) = Fix.message(id: "m1", sender: "sail-clock-pepper") else {
      Issue.record("fixture shape")
      return
    }
    let attributed = message.header.attributing(["sail-clock-pepper": "morgan"])
    #expect(attributed.render().hasPrefix("<sender>morgan (sail-clock-pepper)</sender>\n"))
    #expect(message.header.attributing(["someone-else": "alice"]).render() == message.header.render())
    #expect(message.header.render().hasPrefix("<sender>sail-clock-pepper</sender>\n"))
  }

  @Test func `a device renders last, named at render time like a handle`() {
    guard case let .message(message) = Fix.message(id: "m1", sender: "sail-clock-pepper", device: "brave-fox-hill") else {
      Issue.record("fixture shape")
      return
    }
    let attributed = message.header.attributing(
      ["sail-clock-pepper": "morgan"], devices: ["brave-fox-hill": "Morgan's iPhone"],
    )
    #expect(attributed.render() == """
    <sender>morgan (sail-clock-pepper)</sender>
    <timestamp>2026-01-01T09:00:00+09:00</timestamp>
    <source>conversation/ch1</source>
    <type>message</type>
    <message-id>m1</message-id>
    <device>Morgan's iPhone (brave-fox-hill)</device>
    """)
  }

  @Test func `an unnamed device still renders its id, and no device renders no tag`() {
    guard case let .message(carried) = Fix.message(id: "m1", device: "brave-fox-hill"),
          case let .message(bare) = Fix.message(id: "m1")
    else {
      Issue.record("fixture shape")
      return
    }
    #expect(carried.header.attributing([:]).render().hasSuffix("\n<device>brave-fox-hill</device>"))
    #expect(!bare.header.attributing([:], devices: ["brave-fox-hill": "iPhone"]).render().contains("<device>"))
  }

  @Test func `a direct message carries the device too`() {
    guard case let .direct(message) = Fix.direct(sender: "morgan", device: "brave-fox-hill") else {
      Issue.record("fixture shape")
      return
    }
    #expect(message.header.attributing([:], devices: ["brave-fox-hill": "Studio"]).render() == """
    <sender>morgan</sender>
    <timestamp>2026-01-01T09:00:00+09:00</timestamp>
    <source>direct</source>
    <type>direct message</type>
    <device>Studio (brave-fox-hill)</device>
    """)
  }

  @Test func `direct messages carry the full header and are marked direct`() {
    guard case let .direct(message) = Fix.direct(sender: "morgan") else {
      Issue.record("fixture shape")
      return
    }
    #expect(message.header.render() == """
    <sender>morgan</sender>
    <timestamp>2026-01-01T09:00:00+09:00</timestamp>
    <source>direct</source>
    <type>direct message</type>
    """)
  }
}
