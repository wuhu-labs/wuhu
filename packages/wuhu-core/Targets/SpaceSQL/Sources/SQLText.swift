/// Lexical scans over statement text, for the verdicts SQLite's own answers
/// cannot give.
public enum SQLText {
  /// The first identifier token of `sql` that names one of `names`, lowercased,
  /// skipping comments and string literals.
  public static func identifier(in sql: String, among names: Set<String>) -> String? {
    guard !names.isEmpty else { return nil }
    func match(_ token: some StringProtocol) -> String? {
      let name = token.lowercased()
      return names.contains(name) ? name : nil
    }
    var rest = Substring(sql)
    while let first = rest.first {
      if rest.hasPrefix("--") {
        if let newline = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: newline)...] } else { rest = "" }
      } else if rest.hasPrefix("/*") {
        if let close = rest.range(of: "*/") { rest = rest[close.upperBound...] } else { rest = "" }
      } else if first == "'" || first == "\"" || first == "`" {
        rest = rest.dropFirst()
        let body = rest.prefix { $0 != first }
        rest = rest.dropFirst(body.count + 1)
        if first != "'", let name = match(body) { return name }
      } else if first == "[" {
        rest = rest.dropFirst()
        let body = rest.prefix { $0 != "]" }
        rest = rest.dropFirst(body.count + 1)
        if let name = match(body) { return name }
      } else if first.isLetter || first == "_" {
        let token = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
        rest = rest.dropFirst(token.count)
        if let name = match(token) { return name }
      } else {
        rest = rest.dropFirst()
      }
    }
    return nil
  }

  static func requireLeadingKeyword(_ sql: String) throws(ReadError) {
    var rest = Substring(sql)
    while let first = rest.first {
      if first.isWhitespace { rest = rest.dropFirst(); continue }
      if rest.hasPrefix("--") {
        if let newline = rest.firstIndex(of: "\n") { rest = rest[rest.index(after: newline)...] } else { rest = "" }
        continue
      }
      if rest.hasPrefix("/*") {
        if let close = rest.range(of: "*/") { rest = rest[close.upperBound...] } else { rest = "" }
        continue
      }
      break
    }
    var keyword = ""
    for character in rest {
      if character.isLetter { keyword.append(character) } else { break }
    }
    guard ["select", "with", "values"].contains(keyword.lowercased()) else { throw .notReadOnly }
  }

  static func unknownRelation(_ message: String) -> String? {
    let prefix = "no such table: "
    guard message.hasPrefix(prefix) else { return nil }
    return String(message.dropFirst(prefix.count))
  }
}
