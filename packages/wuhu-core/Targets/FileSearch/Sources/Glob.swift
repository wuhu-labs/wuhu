/// A glob in gitignore's dialect, matched against a `/`-separated path
/// relative to some base (the search root, or a `.gitignore`'s directory).
///
/// A pattern with a `/` before its end is anchored to the base (a leading `/`
/// only anchors); without one it matches the last name at any depth. A
/// trailing `/` matches directories only. `*` and `?` never cross a `/`, a
/// `**` segment spans zero or more segments (one or more when it ends the
/// pattern), `[...]` is a class (`!` or `^` negates, `a-z` ranges) and `\`
/// escapes the next character. Matching is over Unicode scalars.
struct SearchGlob: Hashable, Sendable {
  enum Token: Hashable, Sendable {
    case literal(Unicode.Scalar)
    case any
    case star
    case set([ClosedRange<UInt32>], negated: Bool)
  }

  enum Segment: Hashable, Sendable {
    case anyDepth
    case name([Token])
  }

  let segments: [Segment]
  let directoryOnly: Bool

  init(_ pattern: String) throws(SearchError) {
    func invalid(_ why: String) -> SearchError {
      SearchError(.invalidGlob, "invalid glob \(pattern): \(why)")
    }
    var body = Substring(pattern)
    directoryOnly = body.hasSuffix("/") && !body.hasSuffix("\\/")
    if directoryOnly { body = body.dropLast() }
    let anchored = body.contains("/")
    if body.hasPrefix("/") { body = body.dropFirst() }
    guard !body.isEmpty else { throw invalid("it names no path") }
    var segments: [Segment] = anchored ? [] : [.anyDepth]
    for part in body.split(separator: "/", omittingEmptySubsequences: false) {
      guard !part.isEmpty else { throw invalid("an empty segment (//)") }
      segments.append(part == "**" ? .anyDepth : .name(try Self.tokens(part, invalid)))
    }
    if segments.last == .anyDepth { segments.append(.name([.star])) }
    self.segments = segments
  }

  /// Whether `path` (relative, `/`-separated, nonempty) matches.
  func matches(_ path: String, isDirectory: Bool) -> Bool {
    guard isDirectory || !directoryOnly else { return false }
    let names = path.split(separator: "/", omittingEmptySubsequences: false).map { Array($0.unicodeScalars) }
    // matched[s][n]: segments from s on match names from n on.
    var matched = Array(repeating: Array(repeating: false, count: names.count + 1), count: segments.count + 1)
    matched[segments.count][names.count] = true
    for s in stride(from: segments.count - 1, through: 0, by: -1) {
      for n in stride(from: names.count, through: 0, by: -1) {
        switch segments[s] {
        case .anyDepth:
          matched[s][n] = matched[s + 1][n] || (n < names.count && matched[s][n + 1])
        case let .name(tokens):
          matched[s][n] = n < names.count && matched[s + 1][n + 1] && Self.matches(tokens, names[n])
        }
      }
    }
    return matched[0][0]
  }

  private static func tokens(_ part: Substring, _ invalid: (String) -> SearchError) throws(SearchError) -> [Token] {
    var tokens: [Token] = []
    var scalars = part.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
      switch scalar {
      case "\\":
        guard let escaped = scalars.next() else { throw invalid("a trailing \\") }
        tokens.append(.literal(escaped))
      case "*":
        if tokens.last != .star { tokens.append(.star) }
      case "?":
        tokens.append(.any)
      case "[":
        tokens.append(try set(&scalars, invalid))
      default:
        tokens.append(.literal(scalar))
      }
    }
    return tokens
  }

  private static func set(
    _ scalars: inout Substring.UnicodeScalarView.Iterator, _ invalid: (String) -> SearchError,
  ) throws(SearchError) -> Token {
    var ranges: [ClosedRange<UInt32>] = []
    var negated = false
    var first = true
    var pending: Unicode.Scalar?
    var inRange = false
    func add(_ scalar: Unicode.Scalar) throws(SearchError) {
      if inRange, let low = pending {
        guard low.value <= scalar.value else { throw invalid("a backwards range \(low)-\(scalar)") }
        ranges.append(low.value ... scalar.value)
        pending = nil
        inRange = false
      } else {
        if let low = pending { ranges.append(low.value ... low.value) }
        pending = scalar
      }
    }
    while let scalar = scalars.next() {
      defer { first = false }
      switch scalar {
      case "!" where first && !negated, "^" where first && !negated:
        negated = true
        continue
      case "]" where !(first || (negated && ranges.isEmpty && pending == nil && !inRange)):
        if let low = pending { ranges.append(low.value ... low.value) }
        if inRange { ranges.append(45 ... 45) }
        return .set(ranges, negated: negated)
      case "\\":
        guard let escaped = scalars.next() else { throw invalid("a trailing \\") }
        try add(escaped)
      case "-" where pending != nil && !inRange:
        inRange = true
      default:
        try add(scalar)
      }
    }
    throw invalid("an unterminated [")
  }

  private static func matches(_ tokens: [Token], _ name: [Unicode.Scalar]) -> Bool {
    var t = 0, n = 0
    var star: (token: Int, name: Int)?
    while n < name.count {
      if t < tokens.count {
        switch tokens[t] {
        case .star:
          star = (t, n)
          t += 1
          continue
        case let .literal(scalar) where scalar == name[n]:
          t += 1
          n += 1
          continue
        case .any:
          t += 1
          n += 1
          continue
        case let .set(ranges, negated) where ranges.contains(where: { $0.contains(name[n].value) }) != negated:
          t += 1
          n += 1
          continue
        default:
          break
        }
      }
      guard let last = star else { return false }
      star = (last.token, last.name + 1)
      t = last.token + 1
      n = last.name + 1
    }
    while t < tokens.count, tokens[t] == .star { t += 1 }
    return t == tokens.count
  }
}
