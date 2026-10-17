import struct Foundation.NSRange
import class Foundation.NSRegularExpression

/// Grep's regular expression: ICU's, as NSRegularExpression compiles it.
struct LineMatcher {
  let regex: NSRegularExpression

  init(_ pattern: String) throws(SearchError) {
    do {
      regex = try NSRegularExpression(pattern: pattern)
    } catch {
      throw SearchError(.invalidPattern, "invalid pattern: \(pattern)")
    }
  }

  /// Whether the line holds a match. Cancellation (the deadline's included)
  /// abandons a match that backtracks, and throws.
  func matches(_ line: String) throws -> Bool {
    var found = false
    regex.enumerateMatches(in: line, options: [.reportProgress], range: NSRange(line.startIndex..., in: line)) { result, _, stop in
      if result != nil {
        found = true
        stop.pointee = true
      } else if Task.isCancelled {
        stop.pointee = true
      }
    }
    try Task.checkCancellation()
    return found
  }
}
