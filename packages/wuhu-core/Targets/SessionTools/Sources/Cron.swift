#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

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
    var candidate = Int((date.timeIntervalSince1970 / 60).rounded(.down)) + 1
    let limit = candidate + 4 * 366 * 24 * 60
    while candidate < limit {
      let dayID = floorDivide(candidate, by: 1440)
      let minuteOfDay = candidate - dayID * 1440
      let (month, day) = monthAndDay(dayID)
      let weekday = dayID + 4 - floorDivide(dayID + 4, by: 7) * 7
      guard months.contains(month) else {
        candidate = (dayID + 1) * 1440
        continue
      }
      let dayMatches = switch (dayRestricted, weekdayRestricted) {
      case (true, true): days.contains(day) || weekdays.contains(weekday)
      case (true, false): days.contains(day)
      case (false, true): weekdays.contains(weekday)
      case (false, false): true
      }
      guard dayMatches else {
        candidate = (dayID + 1) * 1440
        continue
      }
      let minute = minuteOfDay % 60
      guard hours.contains(minuteOfDay / 60) else {
        candidate += 60 - minute
        continue
      }
      guard minutes.contains(minute) else {
        candidate += 1
        continue
      }
      return Date(timeIntervalSince1970: Double(candidate * 60))
    }
    return nil
  }
}

private func floorDivide(_ value: Int, by divisor: Int) -> Int {
  let quotient = value / divisor
  return value % divisor < 0 ? quotient - 1 : quotient
}

private func monthAndDay(_ dayID: Int) -> (month: Int, day: Int) {
  // 2000-01-01 is Unix day 10957; Gregorian leap years repeat every 146097 days.
  let daysSince2000 = dayID - 10957
  let era = floorDivide(daysSince2000, by: 146_097)
  var year = 2000 + era * 400
  var dayOfYear = daysSince2000 - era * 146_097
  func leap(_ year: Int) -> Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  }
  while dayOfYear >= (leap(year) ? 366 : 365) {
    dayOfYear -= leap(year) ? 366 : 365
    year += 1
  }
  let lengths = [31, leap(year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  var month = 0
  while dayOfYear >= lengths[month] {
    dayOfYear -= lengths[month]
    month += 1
  }
  return (month + 1, dayOfYear + 1)
}
