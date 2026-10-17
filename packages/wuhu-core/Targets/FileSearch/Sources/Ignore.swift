/// One `.gitignore`: its rules, relative to the directory holding it.
struct IgnoreFile: Sendable {
  struct Rule: Sendable {
    let glob: SearchGlob
    let negated: Bool
  }

  let base: String
  let rules: [Rule]

  /// Blank lines and `#` comments are skipped, `!` negates, `\` escapes a
  /// leading `#` or `!`, trailing spaces are dropped unless escaped. A line
  /// that is no valid glob never matches, as in git.
  init(base: String, text: String) {
    self.base = base
    rules = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { raw in
      var line = raw.hasSuffix("\r") ? raw.dropLast() : raw
      while line.hasSuffix(" "), !line.hasSuffix("\\ ") { line = line.dropLast() }
      guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
      let negated = line.hasPrefix("!")
      if negated { line = line.dropFirst() }
      if line.hasPrefix("\\#") || line.hasPrefix("\\!") { line = line.dropFirst() }
      guard let glob = try? SearchGlob(String(line)) else { return nil }
      return Rule(glob: glob, negated: negated)
    }
  }

  /// True when the last matching rule ignores `path`, false when it
  /// re-includes it, nil when none matches.
  func decision(_ path: String, isDirectory: Bool) -> Bool? {
    let prefix = base == "/" ? "/" : base + "/"
    guard path.utf8.starts(with: prefix.utf8), path.utf8.count > prefix.utf8.count else { return nil }
    let relative = String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
    for rule in rules.reversed() where rule.glob.matches(relative, isDirectory: isDirectory) {
      return !rule.negated
    }
    return nil
  }
}

/// The `.gitignore` files in force at one directory, shallowest first. The
/// deepest file with a matching rule decides.
struct IgnoreStack: Sendable {
  var files: [IgnoreFile] = []

  func ignores(_ path: String, isDirectory: Bool) -> Bool {
    for file in files.reversed() {
      if let ignored = file.decision(path, isDirectory: isDirectory) { return ignored }
    }
    return false
  }
}
