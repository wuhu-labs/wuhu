import Foundation
@testable import SpaceServer
import Testing

@Suite struct NotificationOutboxTests {
  private let now = Date(timeIntervalSince1970: 1_767_225_600)

  @Test(arguments: [
    "Thu, 01 Jan 2026 00:00:30 GMT",
    "Thu, 1 Jan 2026 00:00:30 GMT",
    "Thu., 01 Jan 2026 00:00:30 GMT",
    "Thursday., 01 January 2026 00:00:30 GMT",
    "Thu, 29 Feb 2026 00:00:30 GMT",
    "Thu, 31 Feb 2026 00:00:30 GMT",
    "Thu, 31 Apr 2026 00:00:30 GMT",
    "Thu, 31 Jun 2026 00:00:30 GMT",
    "Thu, 31 Nov 2026 00:00:30 GMT",
    "Thu, 01 Jan 0000 00:00:30 GMT",
    "Thu, 29 Feb 2000 00:00:30 GMT",
    "Thu, 29 Feb 2100 00:00:30 GMT",
    "Thu, 01 Jan 2026 00:00:30 GMT\u{2028}",
    "thu, 01 jan 2026 00:00:30 GMT",
    "Thu, 01 Jan 2026 00:00:30 gmt",
    "Thu, 01 Jan 2026 00:00:30 GMT trailing",
    "Thu, 32 Jan 2026 00:00:30 GMT",
    "Thu, 01 Jan 2026 24:00:30 GMT",
    "Thu, 01 Jan 2026 00:60:30 GMT",
    "Thu, 01 Jan 2026 00:00:60 GMT",
    "Thu, 01 Jan 2026 0:0:30 GMT",
    "Thursday, 01 January 2026 00:00:30 GMT",
    "Thu, 01 Jan 2026 00:00:30.5 GMT",
    "Thursday, 01-Jan-26 00:00:30 GMT",
    "Thu Jan  1 00:00:30 2026",
  ])
  func keepsPreviousHTTPDateAcceptance(header: String) {
    let previous = DateFormatter()
    previous.locale = Locale(identifier: "en_US_POSIX")
    previous.timeZone = TimeZone(secondsFromGMT: 0)
    previous.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'"
    let expected = previous.date(from: header).map { max($0, now) } ?? now.addingTimeInterval(5)
    #expect(outboxRetryDate(header: header, failures: 0, now: now) == expected)
  }

  @Test(arguments: [" ", "\t", "\n", "\r", "\u{000B}", "\u{000C}", "\u{00A0}", "\u{0085}", "\u{1680}", "\u{2000}", "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}"])
  func trailingWhitespaceMatchesPreviousHTTPDateAcceptance(whitespace: String) {
    keepsPreviousHTTPDateAcceptance(header: "Thu, 01 Jan 2026 00:00:30 GMT" + whitespace)
  }

  @Test(arguments: [
    "Thu, 29 Feb 2026 00:00:30 GMT", "Thu, 31 Feb 2026 00:00:30 GMT",
    "Thu, 31 Apr 2026 00:00:30 GMT", "Thu, 31 Jun 2026 00:00:30 GMT",
    "Thu, 31 Nov 2026 00:00:30 GMT", "Thu, 01 Jan 0000 00:00:30 GMT",
    "Thu, 29 Feb 2100 00:00:30 GMT", "Thu, 01 Jan 2026 00:00:30 GMT\u{2028}",
  ])
  func impossibleDatesAndTrailingUnicodeNewlinesUseBackoff(header: String) {
    #expect(outboxRetryDate(header: header, failures: 0, now: now) == now.addingTimeInterval(5))
  }

  @Test(arguments: [2028, 2400])
  func validLeapDaysAreHonored(year: Int) throws {
    let header = "Thu, 29 Feb \(year) 00:00:30 GMT"
    let expected = try Date.ISO8601FormatStyle().parse("\(year)-02-29T00:00:30Z")
    #expect(outboxRetryDate(header: header, failures: 0, now: now) == expected)
  }

  @Test(arguments: [
    ("Thu, 01 Jan 2026 00:00:30 GMT", 30.0),
    ("Wed, 31 Dec 2025 23:59:59 GMT", 0.0),
    ("Sun, 08 Mar 2026 07:00:00 GMT", 5_727_600.0),
    ("Sun, 01 Nov 2026 06:00:00 GMT", 26_287_200.0),
  ])
  func httpDateRetryAfterUsesGMT(sample: (String, Double)) {
    #expect(outboxRetryDate(header: sample.0, failures: 0, now: now) == now.addingTimeInterval(sample.1))
  }

  @Test(arguments: [("0", 0.0), (" 12.5 ", 12.5)])
  func deltaSecondsRetryAfter(sample: (String, Double)) {
    #expect(outboxRetryDate(header: sample.0, failures: 0, now: now) == now.addingTimeInterval(sample.1))
  }

  @Test(arguments: [
    nil,
    "",
    "invalid",
    "-1",
    "Thu, 01 Bad 2026 00:00:30 GMT",
    "Thu, 01 Jan 2026 00:00:30 PST",
    "Thursday, 01-Jan-26 00:00:30 GMT",
    "Thu Jan  1 00:00:30 2026"
  ] as [String?])
  func invalidRetryAfterUsesExistingBackoff(header: String?) {
    #expect(outboxRetryDate(header: header, failures: 2, now: now) == now.addingTimeInterval(20))
    #expect(outboxRetryDate(header: header, failures: 20, now: now) == now.addingTimeInterval(2560))
  }
}
