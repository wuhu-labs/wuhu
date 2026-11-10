import Foundation

enum SQLiteDateFormat {
  static let style: Date.ISO8601FormatStyle = .init(includingFractionalSeconds: true)

  private static let seconds: Date.ISO8601FormatStyle = .init(includingFractionalSeconds: false)

  /// The date's millisecond, floored as the loops' scheduler floors its now: the style alone cuts a Double's digits, and names the millisecond before for half of the dates built from one.
  static func string(from date: Date) -> String {
    let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    let (second, fraction) = milliseconds.quotientAndRemainder(dividingBy: 1000)
    let digits = String(fraction + 1000).dropFirst()
    return seconds.format(Date(timeIntervalSince1970: Double(second))).dropLast() + ".\(digits)Z"
  }

  static func date(from string: String) throws -> Date {
    do {
      return try style.parse(string)
    } catch {
      return try Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(string)
    }
  }
}
