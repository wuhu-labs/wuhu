import Foundation

public enum Glob {
  public static func matches(_ pattern: String, _ path: String) -> Bool {
    var regex = "^"
    var index = pattern.startIndex
    while index < pattern.endIndex {
      let character = pattern[index]
      switch character {
      case "*":
        let next = pattern.index(after: index)
        if next < pattern.endIndex, pattern[next] == "*" {
          regex += ".*"
          index = pattern.index(after: next)
          continue
        }
        regex += "[^/]*"
      case "?":
        regex += "[^/]"
      case ".", "(", ")", "+", "|", "^", "$", "\\", "{", "}", "[", "]":
        regex += "\\" + String(character)
      default:
        regex += String(character)
      }
      index = pattern.index(after: index)
    }
    regex += "$"
    guard let compiled = try? NSRegularExpression(pattern: regex) else { return false }
    let range = NSRange(path.startIndex ..< path.endIndex, in: path)
    return compiled.firstMatch(in: path, range: range) != nil
  }
}
