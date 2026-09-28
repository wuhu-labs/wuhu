import Foundation

/// A compiled glob matcher over `/`-separated relative paths.
///
/// Relocated into `wuhu-vfs` (from the tool layer) so the default `find`/`grep`
/// tree-walk in ``VFSSearch`` is self-contained — the leaf VFS package owns the
/// pure matching logic, and the tool layer (and a remote backend) reuse it.
///
/// Supported syntax: `*` (any run within a path segment), `?` (one non-`/`
/// char), `**/` (zero or more directory segments), `**` (anything). Paths are
/// normalized to forward slashes before matching.
enum VFSGlob {
  struct Matcher {
    private let regex: NSRegularExpression

    init(pattern rawPattern: String, anchored: Bool = true) throws {
      let pattern = VFSGlob.normalize(rawPattern)
      regex = try NSRegularExpression(pattern: VFSGlob.globToRegex(pattern: pattern, anchored: anchored), options: [])
    }

    func matches(path rawPath: String) -> Bool {
      let path = VFSGlob.normalize(rawPath)
      let range = NSRange(path.startIndex ..< path.endIndex, in: path)
      return regex.firstMatch(in: path, options: [], range: range) != nil
    }
  }

  static func normalize(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "/")
  }

  static func compile(pattern: String, anchored: Bool = true) throws -> Matcher {
    try Matcher(pattern: pattern, anchored: anchored)
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
