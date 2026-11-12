#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

func outboxRetryDate(header: String?, failures: Int, now: Date) -> Date {
  if let header, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
    return now.addingTimeInterval(seconds)
  }
  if let header {
    if let date = httpRetryDate(header) { return max(date, now) }
  }
  let seconds = min(3600, 5 * (1 << min(failures, 9)))
  return now.addingTimeInterval(TimeInterval(seconds))
}

private func httpRetryDate(_ header: String) -> Date? {
  let trailingWhitespace = header.reversed().prefix {
    $0.isWhitespace && !$0.isNewline
  }
  let trimmed = header.dropLast(trailingWhitespace.count)
  guard trimmed.hasSuffix("GMT") else { return nil }
  let fields = trimmed.split(whereSeparator: \.isWhitespace)
  guard fields.count == 6,
        [
          "mon,",
          "tue,",
          "wed,",
          "thu,",
          "fri,",
          "sat,",
          "sun,",
          "monday,",
          "tuesday,",
          "wednesday,",
          "thursday,",
          "friday,",
          "saturday,",
          "sunday,",
        ].contains(fields[0].lowercased().replacingOccurrences(of: ".,", with: ",")),
        let month = httpMonths.firstIndex(where: { $0.contains(fields[2].lowercased()) }),
        fields[5] == "GMT"
  else { return nil }
  guard let year = Int(fields[3]), year >= 1,
        let day = Int(fields[1]), day >= 1
  else { return nil }
  let leapYear = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  let daysInMonth = [31, leapYear ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  guard day <= daysInMonth[month] else { return nil }
  let clock = fields[4].split(separator: ":")
  guard clock.count == 3,
        let hour = Int(clock[0]), (0 ..< 24).contains(hour),
        let minute = Int(clock[1]), (0 ..< 60).contains(minute),
        let second = Int(clock[2]), (0 ..< 60).contains(second)
  else { return nil }
  let monthNumber = String(month + 1)
  let iso = "\(fields[3])-\(monthNumber.count == 1 ? "0" : "")\(monthNumber)-\(fields[1])T\(fields[4])Z"
  return try? Date.ISO8601FormatStyle().parse(iso)
}

private let httpMonths = [
  ["jan", "january"], ["feb", "february"], ["mar", "march"], ["apr", "april"],
  ["may"], ["jun", "june"], ["jul", "july"], ["aug", "august"],
  ["sep", "september"], ["oct", "october"], ["nov", "november"], ["dec", "december"],
]
