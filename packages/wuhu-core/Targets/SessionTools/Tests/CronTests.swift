import Foundation
@testable import SessionTools
import Testing

private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
  var components = DateComponents()
  components.year = year
  components.month = month
  components.day = day
  components.hour = hour
  components.minute = minute
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = TimeZone(identifier: "UTC")!
  return calendar.date(from: components)!
}

@Suite struct CronTests {
  @Test func dailyAtNoon() throws {
    let cron = try CronSchedule.parse("0 12 * * *")
    #expect(cron.next(after: utc(2026, 7, 6, 9, 30)) == utc(2026, 7, 6, 12, 0))
    #expect(cron.next(after: utc(2026, 7, 6, 12, 0)) == utc(2026, 7, 7, 12, 0))
  }

  @Test func everyFifteenMinutes() throws {
    let cron = try CronSchedule.parse("*/15 * * * *")
    #expect(cron.next(after: utc(2026, 7, 6, 9, 3)) == utc(2026, 7, 6, 9, 15))
    #expect(cron.next(after: utc(2026, 7, 6, 9, 59)) == utc(2026, 7, 6, 10, 0))
  }

  @Test func weekdayRestriction() throws {
    // 2026-07-06 is a Monday.
    let cron = try CronSchedule.parse("0 9 * * 1")
    #expect(cron.next(after: utc(2026, 7, 6, 10, 0)) == utc(2026, 7, 13, 9, 0))
    let sunday = try CronSchedule.parse("30 8 * * 7")
    #expect(sunday.next(after: utc(2026, 7, 6, 0, 0)) == utc(2026, 7, 12, 8, 30))
  }

  @Test func dayAndWeekdayCombineWithOr() throws {
    let cron = try CronSchedule.parse("0 0 15 * 1")
    // The next Monday (7/13) comes before the 15th.
    #expect(cron.next(after: utc(2026, 7, 6, 1, 0)) == utc(2026, 7, 13, 0, 0))
    #expect(cron.next(after: utc(2026, 7, 13, 1, 0)) == utc(2026, 7, 15, 0, 0))
  }

  @Test func rangesListsAndMonths() throws {
    let cron = try CronSchedule.parse("0 9-11 * 2,8 *")
    #expect(cron.next(after: utc(2026, 7, 6, 0, 0)) == utc(2026, 8, 1, 9, 0))
    #expect(cron.next(after: utc(2026, 8, 1, 9, 0)) == utc(2026, 8, 1, 10, 0))
    #expect(cron.next(after: utc(2026, 8, 31, 11, 0)) == utc(2027, 2, 1, 9, 0))
  }

  @Test(arguments: [812_446_200.0001014, 812_446_259.9990734])
  func axiiaWakeupsAdvanceToTheExactNextSlot(referenceSeconds: Double) throws {
    let cron = try CronSchedule.parse("*/15 * * * *")
    let next = try #require(cron.next(after: Date(timeIntervalSinceReferenceDate: referenceSeconds)))
    #expect(next == utc(2026, 9, 30, 7, 45))
    #expect(next.timeIntervalSince1970 == 1_790_754_300)
  }

  @Test func fractionalTimesAlwaysProduceExactMatchingMinutes() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    for expression in ["* * * * *", "*/15 * * * *", "7,23,59 1,12,23 * * *", "0 9 15 2,8 1"] {
      let cron = try CronSchedule.parse(expression)
      for index in 0 ..< 2000 {
        let seconds = Double(index * 7919 - 8_000_000) + Double(index % 997) / 997
        let after = Date(timeIntervalSince1970: seconds)
        let next = try #require(cron.next(after: after))
        let unixSeconds = next.timeIntervalSince1970
        #expect(unixSeconds == floor(unixSeconds / 60) * 60)
        #expect(next > after)
        let parts = calendar.dateComponents([.minute, .hour, .day, .month, .weekday], from: next)
        #expect(cron.minutes.contains(parts.minute!))
        #expect(cron.hours.contains(parts.hour!))
        #expect(cron.months.contains(parts.month!))
        let day = cron.days.contains(parts.day!)
        let weekday = cron.weekdays.contains(parts.weekday! - 1)
        #expect(
          !cron.dayRestricted && !cron.weekdayRestricted ||
            cron.dayRestricted && day || cron.weekdayRestricted && weekday,
        )
      }
    }
  }

  @Test(arguments: [1600, 1700, 1900, 1969, 2000, 2026, 2100, 2400])
  func integerUtcDecompositionAgreesWithGregorianCalendar(year: Int) throws {
    let cron = try CronSchedule.parse("13 12 1,15,28-31 * *")
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    for month in 1 ... 12 {
      let after = utc(year, month, 1, 0, 0)
      var expected = after
      for _ in 0 ..< 31 {
        let parts = calendar.dateComponents([.day], from: expected)
        if cron.days.contains(parts.day!) { break }
        expected = expected.addingTimeInterval(86400)
      }
      expected = expected.addingTimeInterval(12 * 3600 + 13 * 60)
      #expect(cron.next(after: after) == expected)
      let last = calendar.date(byAdding: .month, value: 1, to: after)!.addingTimeInterval(-60)
      #expect(try #require(cron.next(after: last)) == calendar.date(byAdding: .month, value: 1, to: after)!.addingTimeInterval(12 * 3600 + 13 * 60))
    }
  }

  @Test func leapDaysAndImpossibleSchedules() throws {
    let leapDay = try CronSchedule.parse("0 0 29 2 *")
    #expect(leapDay.next(after: utc(2026, 1, 1, 0, 0)) == utc(2028, 2, 29, 0, 0))
    let impossible = try CronSchedule.parse("0 0 30 2 *")
    #expect(impossible.next(after: utc(2026, 1, 1, 0, 0)) == nil)
    let everyMinute = try CronSchedule.parse("* * * * *")
    #expect(everyMinute.next(after: Date(timeIntervalSince1970: -0.25)) == Date(timeIntervalSince1970: 0))
    #expect(everyMinute.next(after: Date(timeIntervalSince1970: -60)) == Date(timeIntervalSince1970: 0))
  }

  @Test func malformedExpressionsAreRejected() {
    #expect(throws: ToolProblem.self) { try CronSchedule.parse("* * * *") }
    #expect(throws: ToolProblem.self) { try CronSchedule.parse("61 * * * *") }
    #expect(throws: ToolProblem.self) { try CronSchedule.parse("*/0 * * * *") }
    #expect(throws: ToolProblem.self) { try CronSchedule.parse("5-1 * * * *") }
    #expect(throws: ToolProblem.self) { try CronSchedule.parse("not a cron") }
  }
}
