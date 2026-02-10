import Foundation

enum ToolGlob {
  static func normalize(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "/")
  }

  static func matches(pattern rawPattern: String, path rawPath: String, anchored: Bool = true) -> Bool {
    let pattern = normalize(rawPattern)
    let path = normalize(rawPath)
    let regex = globToRegex(pattern: pattern, anchored: anchored)
    guard let re = try? NSRegularExpression(pattern: regex, options: []) else { return false }
    let range = NSRange(path.startIndex ..< path.endIndex, in: path)
    return re.firstMatch(in: path, options: [], range: range) != nil
  }

  private static func globToRegex(pattern: String, anchored: Bool) -> String {
    var out = ""
    if anchored { out += "^" }

    var i = pattern.startIndex
    while i < pattern.endIndex {
      let ch = pattern[i]

      if ch == "*" {
        let next = pattern.index(after: i)
        if next < pattern.endIndex, pattern[next] == "*" {
          let afterStarStar = pattern.index(after: next)
          if afterStarStar < pattern.endIndex, pattern[afterStarStar] == "/" {
            // '**/' matches zero or more directories
            out += "(?:.*/)?"
            i = pattern.index(after: afterStarStar)
            continue
          }
          out += ".*"
          i = afterStarStar
          continue
        }

        out += "[^/]*"
        i = next
        continue
      }

      if ch == "?" {
        out += "[^/]"
        i = pattern.index(after: i)
        continue
      }

      out += NSRegularExpression.escapedPattern(for: String(ch))
      i = pattern.index(after: i)
    }

    if anchored { out += "$" }
    return out
  }
}
