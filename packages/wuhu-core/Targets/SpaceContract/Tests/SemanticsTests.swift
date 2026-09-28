import Foundation
import JSONValue
import SpaceContract
import Testing

@Suite
struct SemanticsTests {
  // Pins SPEC.md: mtime is seconds since the Unix epoch, UTC, fractional. A
  // concrete value is interpreted so a 2001-epoch or milliseconds producer fails
  // here rather than shipping dates 31 years or 1000x off.
  @Test func mtimeIsUnixEpochSecondsUTC() throws {
    let json: JSONValue = .object([
      "name": "a.md", "kind": "file", "size": 1, "token": "t", "mtime": 1_700_000_000,
    ])
    let entry = try JSONValueDecoder().decode(Entry.self, from: json)
    #expect(entry.mtime == 1_700_000_000)

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second],
      from: Date(timeIntervalSince1970: entry.mtime),
    )
    #expect(parts.year == 2023)
    #expect(parts.month == 11)
    #expect(parts.day == 14)
    #expect(parts.hour == 22)
    #expect(parts.minute == 13)
    #expect(parts.second == 20)
  }
}
