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

  @Test func malformedExpressionsAreRejected() {
    #expect(throws: ToolProblem.self) { try CronSchedule.parse("* * * *") }
    #expect(throws: ToolProblem.self) { try CronSchedule.parse("61 * * * *") }
    #expect(throws: ToolProblem.self) { try CronSchedule.parse("*/0 * * * *") }
    #expect(throws: ToolProblem.self) { try CronSchedule.parse("5-1 * * * *") }
    #expect(throws: ToolProblem.self) { try CronSchedule.parse("not a cron") }
  }
}
