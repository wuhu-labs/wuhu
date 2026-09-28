import Foundation

enum SQLiteDateFormat {
  static let style: Date.ISO8601FormatStyle = .init(includingFractionalSeconds: true)

  static func string(from date: Date) -> String {
    style.format(date)
  }

  static func date(from string: String) throws -> Date {
    do {
      return try style.parse(string)
    } catch {
      return try Date.ISO8601FormatStyle(includingFractionalSeconds: false).parse(string)
    }
  }
}
