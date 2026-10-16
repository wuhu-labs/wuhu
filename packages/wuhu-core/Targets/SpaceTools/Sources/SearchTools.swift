import Foundation
import JSONValue
import MachineContract
import SessionDomain
import SpaceContract
import enum SpaceCore.SpaceError
import SpaceFS
import SystemFiles

// The bounds every space search shares, whoever calls it: the tools, run_script
// and pages (anonymous public-read included). A larger limit is capped, not
// refused: the cursor carries the rest.
public enum SearchBounds {
  public static let matchLimit = 1000
  public static let entryLimit = 100_000
  /// Files larger than this are listed in `skipped`, never read.
  public static let fileBytes = 4 << 20
  /// A page stops once it has skipped this many files.
  public static let skippedFiles = 100
  /// Wall time a page may spend before it hands back a step; a page always
  /// advances past at least one file or line first.
  @TaskLocal static var pageBudget: Duration = .seconds(2)
  /// Wall time one line may take to match; a line that needs longer is refused.
  public static let lineBudget: Duration = .seconds(2)
}

extension SpaceToolbox {
  static let grep = SpaceTool("grep", schema: GrepInput.jsonSchema) { (context, input: GrepInput) in
    let target = try context.resolve(input.path ?? "/")
    if let machine = target.machine {
      let query = SearchQuery.grep(
        pattern: input.pattern,
        path: target.path,
        matchLimit: input.matchLimit,
        entryLimit: input.entryLimit,
        step: input.step,
      )
      let result = try await context.machineSearch(machine, query)
      guard case let .matches(matches, cursor) = result else { throw searchFailure(result) }
      let prefix = "machines://\(machine.rawValue)"
      return Wire.object([
        ("matches", .array(matches.map { match in
          Wire.object([
            ("path", .string(prefix + match.path)),
            ("line", .integer(match.line)),
            ("text", .string(ToolOutput.clampedLine(match.text))),
            ("context", .array(match.context.map(JSONValue.string))),
          ])
        })),
        ("cursor", cursor.map(JSONValue.string)),
      ])
    }
    let matchLimit = try boundedLimit(input.matchLimit, name: "matchLimit", default: 50, max: SearchBounds.matchLimit)
    let entryLimit = try boundedLimit(input.entryLimit, name: "entryLimit", default: 1000, max: SearchBounds.entryLimit)
    let regex: NSRegularExpression
    do {
      regex = try NSRegularExpression(pattern: input.pattern)
    } catch {
      throw ToolRunError.failed(code: .invalidArgument, message: "invalid pattern: \(input.pattern)", hint: nil)
    }
    let scope = SearchScope(kind: "grep", query: input.pattern, target: target)
    let resume = try input.step.map(scope.resume)
    let walk = SearchWalk(
      backend: target.backend, entryLimit: entryLimit, deadline: ContinuousClock.now + SearchBounds.pageBudget, resume: resume?.path,
    )

    var matches: [JSONValue] = []
    var skipped: [JSONValue] = []
    var examined = 0
    var next: SearchCursor?
    // Records a file it will not read; false once the page holds enough of them.
    func skip(_ file: String, bytes: Int) -> Bool {
      guard skipped.count < SearchBounds.skippedFiles else {
        next = scope.cursor(file)
        return false
      }
      skipped.append(Wire.object([("path", .string(target.rendered(file))), ("bytes", .integer(bytes)), ("reason", .string("tooLarge"))]))
      return true
    }
    try await walk.run(root: target.path) { file, entry in
      guard entry.kind == .file else { return true }
      let data: Data
      switch try await searchable(target.backend, file, listedSize: entry.size) {
      case let .text(bytes): data = bytes
      case let .tooLarge(bytes): return skip(file, bytes: bytes)
      }
      let startLine = resume.map { file == $0.path ? $0.line : 1 } ?? 1
      let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() where index + 1 >= startLine {
        let text = String(line)
        // The page's first line gets a budget of its own, so listing and
        // reading cannot use it all up and every page examines a line.
        let outcome = firstMatch(regex, text, before: examined == 0 ? ContinuousClock.now + SearchBounds.lineBudget : walk.deadline)
        switch outcome {
        case .match: break
        case .noMatch:
          examined += 1
          continue
        case .outOfTime where examined == 0:
          throw ToolRunError.failed(
            code: .invalidArgument,
            message: "matching \(target.rendered(file)):\(index + 1) took longer than \(SearchBounds.lineBudget)",
            hint: "simplify the pattern (nested quantifiers backtrack)",
          )
        case .outOfTime:
          next = scope.cursor(file, line: index + 1)
          return false
        }
        if matches.count == matchLimit {
          next = scope.cursor(file, line: index + 1)
          return false
        }
        examined += 1
        matches.append(Wire.object([
          ("path", .string(target.rendered(file))),
          ("line", .integer(index + 1)),
          ("text", .string(ToolOutput.clampedLine(text))),
          ("context", .array([])),
        ]))
      }
      return true
    }
    var fields: [(String, JSONValue?)] = [("matches", .array(matches)), ("cursor", (next ?? walk.next.map { scope.cursor($0) }).map { .string($0.encoded) })]
    if !skipped.isEmpty { fields.append(("skipped", .array(skipped))) }
    return Wire.object(fields)
  }

  static let find = SpaceTool("find", schema: FindInput.jsonSchema) { (context, input: FindInput) in
    let target = try context.resolve(input.path ?? "/")
    if let machine = target.machine {
      let query = SearchQuery.find(
        glob: input.glob,
        path: target.path,
        matchLimit: input.matchLimit,
        entryLimit: input.entryLimit,
        step: input.step,
      )
      let result = try await context.machineSearch(machine, query)
      guard case let .paths(paths, cursor) = result else { throw searchFailure(result) }
      let prefix = "machines://\(machine.rawValue)"
      return Wire.object([
        ("paths", .array(paths.map { .string(prefix + $0) })),
        ("cursor", cursor.map(JSONValue.string)),
      ])
    }
    let matchLimit = try boundedLimit(input.matchLimit, name: "matchLimit", default: 50, max: SearchBounds.matchLimit)
    let entryLimit = try boundedLimit(input.entryLimit, name: "entryLimit", default: 1000, max: SearchBounds.entryLimit)
    let scope = SearchScope(kind: "find", query: input.glob, target: target)
    let resume = try input.step.map(scope.resume)
    let walk = SearchWalk(
      backend: target.backend, entryLimit: entryLimit, deadline: ContinuousClock.now + SearchBounds.pageBudget, resume: resume?.path,
    )

    var paths: [JSONValue] = []
    var next: String?
    try await walk.run(root: target.path) { path, _ in
      guard Glob.matches(input.glob, path) else { return true }
      if paths.count == matchLimit {
        next = path
        return false
      }
      paths.append(.string(target.rendered(path)))
      return true
    }
    let cursor = (next ?? walk.next).map { scope.cursor($0) }
    return Wire.object([("paths", .array(paths)), ("cursor", cursor.map { .string($0.encoded) })])
  }
}

enum Searchable: Equatable {
  case text(Data)
  case tooLarge(Int)
}

/// A file's bytes when within the bound, else the size that ruled it out.
/// The listed size can be stale, so what was read is checked again.
func searchable(_ backend: any SpaceVFS, _ file: String, listedSize: Int) async throws -> Searchable {
  guard listedSize <= SearchBounds.fileBytes else { return .tooLarge(listedSize) }
  let (_, data) = try await backend.read(file)
  return data.count <= SearchBounds.fileBytes ? .text(data) : .tooLarge(data.count)
}

private func searchFailure(_ result: SearchResult) -> ToolRunError {
  guard case let .error(error) = result else {
    return .failed(code: .internal, message: "machine returned an unexpected search result", hint: nil)
  }
  return machineFailure(error)
}

private func boundedLimit(_ value: Int?, name: String, default defaultValue: Int, max: Int) throws -> Int {
  guard let value else { return defaultValue }
  guard value >= 1 else {
    throw ToolRunError.failed(code: .invalidArgument, message: "\(name) must be a positive integer, got \(value)", hint: nil)
  }
  return min(value, max)
}

private enum MatchOutcome: Equatable {
  case match
  case noMatch
  /// The budget ran out; `inMatch` when ICU's progress report caught it
  /// inside this line's match rather than before it started.
  case outOfTime(inMatch: Bool)
}

private func firstMatch(_ regex: NSRegularExpression, _ text: String, before deadline: ContinuousClock.Instant) -> MatchOutcome {
  guard ContinuousClock.now < deadline else { return .outOfTime(inMatch: false) }
  var found = false
  var expired = false
  regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(text.startIndex..., in: text)) { result, _, stop in
    if result != nil {
      found = true
      stop.pointee = true
    } else if ContinuousClock.now >= deadline {
      expired = true
      stop.pointee = true
    }
  }
  return found ? .match : expired ? .outOfTime(inMatch: true) : .noMatch
}

// A step is opaque: it names the search it continues (tool, query, the
// backend the path resolved to, root) and a position in walk order, so a step
// from another search or a hand-made one is refused rather than silently misread.
private struct SearchScope {
  let kind: String
  let query: String
  let backend: String
  let root: String

  init(kind: String, query: String, target: SpaceToolContext.Target) {
    self.kind = kind
    self.query = query
    backend = target.system ? "system" : "group:\(target.group?.rawValue ?? "")"
    root = target.path
  }

  private var header: String {
    "\(kind)\n\(Self.digest(query))\n\(backend)\n\(root)"
  }

  func cursor(_ path: String, line: Int = 1) -> SearchCursor {
    SearchCursor(header: header, path: path, line: line)
  }

  func resume(_ step: String) throws -> SearchCursor {
    let invalid = ToolRunError.failed(
      code: .invalidArgument,
      message: "invalid step: pass back a step this \(kind) returned, with the same \(kind == "find" ? "glob" : "pattern") and path",
      hint: nil,
    )
    guard step.hasPrefix(SearchCursor.version), let data = base64URLDecoded(String(step.dropFirst(SearchCursor.version.count))) else { throw invalid }
    let text = String(decoding: data, as: UTF8.self)
    guard text.hasPrefix(header + "\n") else { throw invalid }
    let parts = text.dropFirst(header.count + 1).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2, let line = Int(parts[0]), line >= 1 else { throw invalid }
    let path = String(parts[1])
    guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { throw invalid }
    return SearchCursor(header: header, path: path, line: line)
  }

  // FNV-1a: binds a step to its query; not a secret.
  private static func digest(_ text: String) -> String {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    for byte in text.utf8 {
      hash ^= UInt64(byte)
      hash = hash &* 0x0000_0100_0000_01B3
    }
    return String(hash, radix: 16)
  }
}

private struct SearchCursor {
  static let version = "s1."

  let header: String
  let path: String
  let line: Int

  var encoded: String {
    Self.version + base64URL(Data("\(header)\n\(line)\n\(path)".utf8))
  }
}

private func base64URL(_ data: Data) -> String {
  data.base64EncodedString()
    .replacingOccurrences(of: "+", with: "-")
    .replacingOccurrences(of: "/", with: "_")
    .replacingOccurrences(of: "=", with: "")
}

private func base64URLDecoded(_ text: String) -> Data? {
  guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
  var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
  base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
  return Data(base64Encoded: base64)
}

extension String {
  // Byte order, SQLite's: `<` on String compares canonically equivalent forms.
  fileprivate func bytesPrecede(_ other: String) -> Bool {
    utf8.lexicographicallyPrecedes(other.utf8)
  }
}

// Leaves stream in the byte order of their full paths, the order the
// machine agent's traversal gives. Only leaves count against the bound (space
// directories are implicit, so each one holds a leaf), and the walk stops
// before a leaf once the bound or the deadline is reached, the deadline only
// after at least one leaf so every page advances. Positions are keys: a leaf's
// path, a directory's path plus "/". Directories are listed a page at a time,
// from the resume position on; subtrees wholly before it are never listed.
// Concurrent writes are best effort: an entry created before the position is
// not seen on later pages.
final class SearchWalk {
  static let pageSize = 256

  let backend: any SpaceVFS
  let entryLimit: Int
  let deadline: ContinuousClock.Instant
  private let resume: String?
  private var scanned = 0
  /// Where the next page starts, when the bound or the deadline stopped the walk.
  private(set) var next: String?

  init(backend: any SpaceVFS, entryLimit: Int, deadline: ContinuousClock.Instant, resume: String?) {
    self.backend = backend
    self.entryLimit = entryLimit
    self.deadline = deadline
    self.resume = resume
  }

  /// `visit` sees each leaf (non-directory entry) and returns false to stop the walk.
  func run(root: String, visit: (String, SpaceFS.Entry) async throws -> Bool) async throws {
    if root != "/" {
      let entry = try await backend.stat(root)
      if entry.kind != .directory {
        if let resume, root.bytesPrecede(resume) { return }
        _ = try await leaf(root, entry, visit)
        return
      }
    }
    _ = try await directory(root, resume: resume, visit)
  }

  private func leaf(_ path: String, _ entry: SpaceFS.Entry, _ visit: (String, SpaceFS.Entry) async throws -> Bool) async throws -> Bool {
    guard scanned < entryLimit, scanned == 0 || ContinuousClock.now < deadline else {
      next = path
      return false
    }
    scanned += 1
    return try await visit(path, entry)
  }

  // A directory sorts among its siblings as `name/`, so it follows the
  // siblings that extend its name with a byte below "/" (`a-b` before `a/`).
  // Those come right after it in name order, so a directory waits on a stack
  // until a sibling's key passes its own.
  private func directory(
    _ directory: String, resume: String?, _ visit: (String, SpaceFS.Entry) async throws -> Bool,
  ) async throws -> Bool {
    let prefix = directory == "/" ? "/" : directory + "/"
    var waiting: [String] = []
    var from = ""
    if let resume, resume.utf8.starts(with: prefix.utf8), resume.utf8.count > prefix.utf8.count {
      let rest = resume.utf8.dropFirst(prefix.utf8.count)
      let name = String(decoding: rest.prefix { $0 != UInt8(ascii: "/") }, as: UTF8.self)
      waiting = try await waitingDirectories(before: name, in: prefix)
      if name.utf8.count < rest.count {
        if try await isDirectory(prefix + name) {
          guard try await self.directory(prefix + name, resume: resume, visit) else { return false }
        }
        from = name + "0"
      } else {
        from = name
      }
    }
    while true {
      let (entries, more) = try await backend.list(directory, from: from, limit: Self.pageSize)
      for entry in entries {
        let key = entry.kind == .directory ? entry.name + "/" : entry.name
        while let top = waiting.last, (top + "/").bytesPrecede(key) {
          waiting.removeLast()
          guard try await self.directory(prefix + top, resume: nil, visit) else { return false }
        }
        if entry.kind == .directory {
          waiting.append(entry.name)
        } else {
          guard try await leaf(prefix + entry.name, entry, visit) else { return false }
        }
      }
      guard let more else { break }
      from = more
    }
    while let top = waiting.popLast() {
      guard try await self.directory(prefix + top, resume: nil, visit) else { return false }
    }
    return true
  }

  /// The directories a resume at `name` finds still waiting: its prefixes
  /// followed by a byte below "/", shortest first.
  private func waitingDirectories(before name: String, in prefix: String) async throws -> [String] {
    var found: [String] = []
    var scalars = String.UnicodeScalarView()
    for scalar in name.unicodeScalars {
      if scalar.value < 0x2F, !scalars.isEmpty, try await isDirectory(prefix + String(scalars)) {
        found.append(String(scalars))
      }
      scalars.append(scalar)
    }
    return found
  }

  private func isDirectory(_ path: String) async throws -> Bool {
    do {
      return try await backend.stat(path).kind == .directory
    } catch SpaceError.notFound {
      return false
    }
  }
}
