import Foundation

/// A minimal `.gitignore` matcher over root-relative paths.
///
/// Relocated into `wuhu-vfs` so the default `find`/`grep` walk is self-contained.
/// Rules are parsed from a `.gitignore` and evaluated against a directory entry's
/// path *relative to the search root*. A rule's `baseDir` is the search-root-
/// relative path of the directory that contained the `.gitignore` (empty for the
/// root's own file). This is the common-case subset of gitignore semantics
/// (anchored `/`, dir-only `/`-suffix, `**`, bare-name vs path patterns);
/// negation (`!`) and comments are ignored, matching the prior tool behavior.
enum VFSGitignore {
  struct Rule {
    /// Search-root-relative directory the `.gitignore` lives in (`""` = root).
    var baseDir: String
    var isDirOnly: Bool
    var hasSlash: Bool
    var anchored: Bool
    private var matcher: VFSGlob.Matcher

    init(baseDir: String, pattern: String, isDirOnly: Bool, anchored: Bool, hasSlash: Bool) throws {
      self.baseDir = baseDir
      self.isDirOnly = isDirOnly
      self.hasSlash = hasSlash
      self.anchored = anchored
      matcher = try VFSGlob.compile(pattern: pattern, anchored: anchored || !hasSlash)
    }

    /// Whether `relativePath` (search-root-relative, `/`-separated) is matched.
    func matches(relativePath: String, isDirectory: Bool) -> Bool {
      if isDirOnly, !isDirectory { return false }

      // The entry must live under this rule's base directory.
      let basePrefix = baseDir.isEmpty ? "" : baseDir + "/"
      guard baseDir.isEmpty || relativePath == baseDir || relativePath.hasPrefix(basePrefix) else {
        return false
      }

      let relativeToBase = baseDir.isEmpty
        ? relativePath
        : String(relativePath.dropFirst(basePrefix.count))
      let basename = relativePath.split(separator: "/").last.map(String.init) ?? relativePath

      if hasSlash || anchored {
        return matcher.matches(path: relativeToBase)
      }
      return matcher.matches(path: basename)
    }
  }

  static func parse(text rawText: String, baseDir: String) -> [Rule] {
    let text = rawText.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { return nil }

      var pattern = line
      var anchored = false
      if pattern.hasPrefix("/") {
        anchored = true
        pattern = String(pattern.dropFirst())
      }

      var isDirOnly = false
      if pattern.hasSuffix("/") {
        isDirOnly = true
        pattern = String(pattern.dropLast())
      }

      let hasSlash = pattern.contains("/")
      guard !pattern.isEmpty else { return nil }
      return try? Rule(baseDir: baseDir, pattern: pattern, isDirOnly: isDirOnly, anchored: anchored, hasSlash: hasSlash)
    }
  }

  static func isIgnored(relativePath: String, isDirectory: Bool, rules: [Rule]) -> Bool {
    rules.contains { $0.matches(relativePath: relativePath, isDirectory: isDirectory) }
  }
}
