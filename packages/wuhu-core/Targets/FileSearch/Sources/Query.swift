/// One find or grep, the same on every backend: a pattern under a root, and
/// where a previous page stopped.
public struct SearchQuery: Codable, Hashable, Sendable {
  public enum Mode: String, Codable, Hashable, Sendable {
    /// `pattern` is a glob matched against paths relative to `root`.
    case find
    /// `pattern` is an ICU regular expression matched against each line.
    case grep
  }

  public var mode: Mode
  public var pattern: String
  /// An absolute path; a directory is walked, a file searched alone.
  public var root: String
  /// What `root` is a path in (a space group, a machine, the system files),
  /// named by the caller; a cursor continues only in the scope that made it.
  public var scope: String
  /// Walk hidden entries too.
  public var hidden: Bool
  /// Walk what `.gitignore` files exclude too.
  public var noIgnore: Bool
  /// Most hits in a page; nil is ``SearchLimits/defaultLimit``, larger is
  /// capped at ``SearchLimits/maxLimit``.
  public var limit: Int?
  /// A page's cursor, to continue where it stopped.
  public var step: String?

  public init(
    mode: Mode, pattern: String, root: String, scope: String, hidden: Bool = false, noIgnore: Bool = false, limit: Int? = nil,
    step: String? = nil,
  ) {
    self.mode = mode
    self.pattern = pattern
    self.root = root
    self.scope = scope
    self.hidden = hidden
    self.noIgnore = noIgnore
    self.limit = limit
    self.step = step
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    mode = try container.decode(Mode.self, forKey: .mode)
    pattern = try container.decode(String.self, forKey: .pattern)
    root = try container.decode(String.self, forKey: .root)
    scope = try container.decode(String.self, forKey: .scope)
    hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    noIgnore = try container.decodeIfPresent(Bool.self, forKey: .noIgnore) ?? false
    limit = try container.decodeIfPresent(Int.self, forKey: .limit)
    step = try container.decodeIfPresent(String.self, forKey: .step)
  }
}

/// One page of results. `cursor` is present iff the page stopped before the
/// walk ended; passing it back as `step` continues exactly there.
public struct SearchPage: Codable, Hashable, Sendable {
  public var hits: [SearchHit]
  public var cursor: String?
  /// Entries this page visited, skipped ones included.
  public var scanned: Int
  /// What this page passed over, one entry per reason, in reason order.
  public var skipped: [SearchSkip]

  public init(hits: [SearchHit], cursor: String?, scanned: Int, skipped: [SearchSkip]) {
    self.hits = hits
    self.cursor = cursor
    self.scanned = scanned
    self.skipped = skipped
  }
}

/// A find hit is a path; a grep hit also has the 1-based line and its text,
/// clamped past ``SearchLimits/shownLineBytes``.
public struct SearchHit: Codable, Hashable, Sendable {
  public var path: String
  public var line: Int?
  public var text: String?

  public init(path: String, line: Int? = nil, text: String? = nil) {
    self.path = path
    self.line = line
    self.text = text
  }
}

public enum SearchSkipReason: String, Codable, CaseIterable, Comparable, Sendable {
  /// A hidden entry, not walked (``SearchQuery/hidden`` walks it).
  case hidden
  /// Excluded by a `.gitignore`, not walked (``SearchQuery/noIgnore`` walks it).
  case ignored
  /// A file with a NUL byte in its first chunk, not read.
  case binary
  /// A file with a line over ``SearchLimits/lineBytes``; the rest of it is not read.
  case longLine
  /// An entry the backend could not list or read.
  case unreadable

  public static func < (lhs: Self, rhs: Self) -> Bool {
    allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
  }
}

public struct SearchSkip: Codable, Hashable, Sendable {
  public var reason: SearchSkipReason
  public var count: Int
  /// The first path skipped for this reason.
  public var example: String

  public init(reason: SearchSkipReason, count: Int, example: String) {
    self.reason = reason
    self.count = count
    self.example = example
  }
}

public struct SearchError: Error, Codable, Hashable, Sendable {
  public enum Code: String, Codable, Hashable, Sendable {
    case invalidPattern
    case invalidGlob
    case invalidStep
    case invalidLimit
    case notFound
    /// The search ran past ``SearchLimits/deadline``; no partial page.
    case timeout
  }

  public var code: Code
  public var message: String

  public init(_ code: Code, _ message: String) {
    self.code = code
    self.message = message
  }
}

/// Every bound a page has. A page ends on counts and bytes only, never on
/// time, so a query pages the same way however loaded its backend is.
public enum SearchLimits {
  public static let defaultLimit = 50
  public static let maxLimit = 1000
  /// Hits and skip examples, JSON-escaped; a page's first hit always fits.
  public static let pageBytes = 48 << 10
  /// Entries visited by a page.
  public static let pageEntries = 10000
  /// File bytes read by a page: searched files, binary ones included, and
  /// `.gitignore` files.
  public static let pageReadBytes = 16 << 20
  /// The longest line grep reads, and the size of each read.
  public static let lineBytes = 64 << 10
  public static let shownLineBytes = 500
  public static let patternBytes = 4096
  /// A `.gitignore` this size or larger is skipped as unreadable; a smaller
  /// one is read in one read.
  public static let ignoreFileBytes = 64 << 10
  /// The part of ``pageReadBytes`` the `.gitignore` files above the root
  /// may take; each is reserved at ``ignoreFileBytes`` before it is read.
  public static let ancestorIgnoreBytes = 8 << 20
  /// A search still running this long fails ``SearchError/Code/timeout``.
  public static let deadline: Duration = .seconds(30)
}
