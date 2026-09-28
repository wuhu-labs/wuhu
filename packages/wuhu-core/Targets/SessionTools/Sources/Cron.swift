import Foundation

// Five-field cron (minute hour day-of-month month day-of-week), UTC.
// Supports *, */n, a-b, a-b/n, and comma lists; day-of-month and day-of-week
// combine with OR when both are restricted, per POSIX.
struct CronSchedule: Hashable, Sendable {
  var minutes: Set<Int>
  var hours: Set<Int>
  var days: Set<Int>
  var months: Set<Int>
  var weekdays: Set<Int>
  var dayRestricted: Bool
  var weekdayRestricted: Bool

  static func parse(_ expression: String) throws(ToolProblem) -> CronSchedule {
    let fields = expression.split(separator: " ").map(String.init)
    guard fields.count == 5 else {
      throw ToolProblem("cron expression needs 5 fields (minute hour day month weekday), got \(fields.count)")
    }
    return CronSchedule(
      minutes: try field(fields[0], 0 ... 59),
      hours: try field(fields[1], 0 ... 23),
      days: try field(fields[2], 1 ... 31),
      months: try field(fields[3], 1 ... 12),
      weekdays: Set(try field(fields[4], 0 ... 7).map { $0 == 7 ? 0 : $0 }),
      dayRestricted: fields[2] != "*",
      weekdayRestricted: fields[4] != "*",
    )
  }

  private static func field(_ text: String, _ range: ClosedRange<Int>) throws(ToolProblem) -> Set<Int> {
    var values: Set<Int> = []
    for part in text.split(separator: ",") {
      let (body, step): (Substring, Int)
      if let slash = part.firstIndex(of: "/") {
        guard let parsed = Int(part[part.index(after: slash)...]), parsed >= 1 else {
          throw ToolProblem("invalid cron step in \(part)")
        }
        (body, step) = (part[..<slash], parsed)
      } else {
        (body, step) = (part, 1)
      }
      let span: ClosedRange<Int>
      if body == "*" {
        span = range
      } else if let dash = body.firstIndex(of: "-") {
        guard let low = Int(body[..<dash]), let high = Int(body[body.index(after: dash)...]),
              range.contains(low), range.contains(high), low <= high
        else { throw ToolProblem("invalid cron range in \(part)") }
        span = low ... high
      } else {
        guard let value = Int(body), range.contains(value) else {
          throw ToolProblem("invalid cron value in \(part)")
        }
        span = value ... value
      }
      values.formUnion(stride(from: span.lowerBound, through: span.upperBound, by: step))
    }
    return values
  }

  func next(after date: Date) -> Date? {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let remainder = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60)
    var candidate = date.addingTimeInterval(60 - remainder)
    // Bounded by construction: any satisfiable schedule fires within 4 years
    // (leap-day worst case); day-level skips keep the walk cheap.
    let limit = candidate.addingTimeInterval(4 * 366 * 24 * 3600)
    while candidate < limit {
      let parts = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: candidate)
      guard months.contains(parts.month!) else {
        candidate = nextDay(after: candidate, calendar: calendar)
        continue
      }
      let dayMatches = switch (dayRestricted, weekdayRestricted) {
      case (true, true): days.contains(parts.day!) || weekdays.contains(parts.weekday! - 1)
      case (true, false): days.contains(parts.day!)
      case (false, true): weekdays.contains(parts.weekday! - 1)
      case (false, false): true
      }
      guard dayMatches else {
        candidate = nextDay(after: candidate, calendar: calendar)
        continue
      }
      guard hours.contains(parts.hour!) else {
        candidate = candidate.addingTimeInterval(TimeInterval((60 - parts.minute!) * 60))
        continue
      }
      guard minutes.contains(parts.minute!) else {
        candidate = candidate.addingTimeInterval(60)
        continue
      }
      return candidate
    }
    return nil
  }

  private func nextDay(after date: Date, calendar: Calendar) -> Date {
    calendar.startOfDay(for: date).addingTimeInterval(24 * 3600)
  }
}
