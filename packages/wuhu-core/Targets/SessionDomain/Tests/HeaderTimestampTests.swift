#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import Testing

@Suite struct HeaderTimestampTests {
  @Test(arguments: [
    ("Asia/Tokyo", "2026-01-01T09:00:00+09:00"),
    ("Asia/Kolkata", "2026-01-01T05:30:00+05:30"),
    ("America/New_York", "2025-12-31T19:00:00-05:00"),
  ])
  func namedSenderZonesRenderInternetDateTime(sample: (String, String)) throws {
    let zone = try #require(TimeZone(identifier: sample.0))
    let header = MessageHeader(sender: "alice", timestamp: Date(timeIntervalSince1970: 1_767_225_600.999), timeZone: zone, source: .direct, kind: .message)
    #expect(header.render() == """
    <sender>alice</sender>
    <timestamp>\(sample.1)</timestamp>
    <source>direct</source>
    <type>message</type>
    """)
  }

  @Test func systemNoticesRenderUTC() {
    let header = MessageHeader.systemNotice(source: SubscriptionID("notice"), at: Date(timeIntervalSince1970: 1_767_225_600))
    #expect(header.render() == """
    <sender>system</sender>
    <timestamp>2026-01-01T00:00:00Z</timestamp>
    <source>notice</source>
    <type>system notice</type>
    """)
  }

  @Test(arguments: [
    (0, "2026-01-01T00:00:00Z"),
    (19800, "2026-01-01T05:30:00+05:30"),
    (-12600, "2025-12-31T20:30:00-03:30"),
  ])
  func fixedOffsetsRenderInternetDateTime(sample: (Int, String)) throws {
    let zone = try #require(TimeZone(secondsFromGMT: sample.0))
    let header = MessageHeader(sender: "alice", timestamp: Date(timeIntervalSince1970: 1_767_225_600.999), timeZone: zone, source: .direct, kind: .message)
    #expect(header.render() == """
    <sender>alice</sender>
    <timestamp>\(sample.1)</timestamp>
    <source>direct</source>
    <type>message</type>
    """)
  }
}
