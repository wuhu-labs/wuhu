import struct Foundation.NSRange
import class Foundation.NSRegularExpression
import struct OperationProtocol.OperationClock
import struct OperationProtocol.OperationError
import struct OperationRuntime.OperationCancellation

enum GrepMatcher: Sendable {
  case literal(String)
  case regex(NSRegularExpression)

  init(pattern: String, dialect: String?) throws {
    switch dialect {
    case "literal": self = .literal(pattern)
    case "regex":
      do { self = .regex(try NSRegularExpression(pattern: pattern)) }
      catch { throw OperationError(.invalidInput, message: "Invalid ICU regular expression") }
    default: throw OperationError(.unsupportedDialect, details: ["supported": ["literal", "regex"]])
    }
  }

  func matches(_ text: String, cancellation: OperationCancellation) async throws -> Bool {
    switch self {
    case let .literal(pattern): return text.contains(pattern)
    case let .regex(pattern):
      do { return try await withThrowingTaskGroup(of: Bool.self) { group in
        defer { group.cancelAll() }
        group.addTask {
          var found = false
          pattern.enumerateMatches(in: text, options: .reportProgress, range: NSRange(text.startIndex..., in: text)) { match, _, stop in
            if Task.isCancelled { stop.pointee = true }
            else if match != nil { found = true; stop.pointee = true }
          }
          guard !Task.isCancelled else { throw OperationError(.requestCancelled) }
          return found
        }
        group.addTask {
          let clock = OperationClock.continuous
          while true {
            try await cancellation.check()
            try await clock.sleep(.milliseconds(10))
          }
        }
        return try await group.next()!
      } } catch is CancellationError { throw OperationError(.requestCancelled) }
    }
  }
}
