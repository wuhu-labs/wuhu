import protocol Clocks.NonsendingClock
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

extension SearchQuery {
  /// One page of this search over `source`. The walk is depth-first, siblings
  /// in UTF-8 byte order of their names, so pages are deterministic: the same
  /// tree and query page the same way on every backend.
  ///
  /// Query errors are ``SearchError``s; so is running past
  /// ``SearchLimits/deadline`` on `clock`, timed on the caller's isolation, which cancels the walk. Any error a
  /// source throws other than ``SearchUnreadable`` ends the search.
  public func run(
    in source: some SearchSource, clock: any NonsendingClock<Duration> = ContinuousClock(), isolation: isolated (any Actor)? = #isolation,
  ) async throws -> SearchPage {
    try await run(in: source, clock: clock, readBudget: SearchLimits.pageReadBytes)
  }

  func run(
    in source: some SearchSource, clock: some NonsendingClock<Duration>, readBudget: Int, isolation: isolated (any Actor)? = #isolation,
  ) async throws -> SearchPage {
    let deadline = clock.now.advanced(by: SearchLimits.deadline)
    return try await withThrowingTaskGroup(of: SearchPage?.self) { group in
      defer { group.cancelAll() }
      group.addTask { try await Walker(self, source, readBudget: readBudget).run() }
      group.addTask {
        try await clock.sleep(until: deadline, tolerance: nil, isolation: isolation)
        return nil
      }
      guard let page = try await group.next() ?? nil else {
        throw SearchError(
          .timeout,
          "search took longer than \(SearchLimits.deadline.components.seconds) s; narrow the path, or simplify the pattern (nested quantifiers backtrack)",
        )
      }
      return page
    }
  }
}

extension SearchQuery {
  /// Throws the ``SearchError`` this query fails with before any walk: a bad
  /// pattern, limit or step. ``run(in:clock:)`` checks the same first.
  public func validate() throws(SearchError) {
    _ = try Walker(self, NoSource())
  }
}

/// The source ``SearchQuery/validate()`` never walks.
private struct NoSource: SearchSource {
  func kind(_: String) async throws -> SearchEntryKind? { nil }
  func children(of _: String, from _: String, limit _: Int) async throws -> SearchListing { SearchListing(children: [], next: nil) }
  func open(_: String) async throws -> any SearchReader { throw SearchUnreadable("no source") }
  func isHidden(_: String) -> Bool { false }
}

private final class Walker<Source: SearchSource> {
  enum Matcher {
    case find(SearchGlob)
    case grep(LineMatcher)
  }

  let query: SearchQuery
  let source: Source
  let matcher: Matcher
  let limit: Int
  let readBudget: Int
  let resume: SearchCursor?

  var hits: [SearchHit] = []
  var bytes = 0
  var scanned = 0
  /// File bytes this page read: searched files and `.gitignore` files.
  var readBytes = 0
  /// Chunks of searched files this page read.
  var chunks = 0
  var skips: [SearchSkipReason: SearchSkip] = [:]
  var cursor: SearchCursor?

  init(_ query: SearchQuery, _ source: Source, readBudget: Int = SearchLimits.pageReadBytes) throws(SearchError) {
    var query = query
    guard query.root.hasPrefix("/") else { throw SearchError(.notFound, "not an absolute path: \(query.root)") }
    while query.root.count > 1, query.root.hasSuffix("/") { query.root.removeLast() }
    guard query.pattern.utf8.count <= SearchLimits.patternBytes else {
      throw SearchError(query.mode == .find ? .invalidGlob : .invalidPattern, "pattern is over \(SearchLimits.patternBytes) bytes")
    }
    switch query.limit {
    case nil: limit = SearchLimits.defaultLimit
    case let value? where value >= 1: limit = min(value, SearchLimits.maxLimit)
    case let value?: throw SearchError(.invalidLimit, "limit must be a positive integer, got \(value)")
    }
    switch query.mode {
    case .find: matcher = .find(try SearchGlob(query.pattern))
    case .grep: matcher = .grep(try LineMatcher(query.pattern))
    }
    resume = try query.step.map { step throws(SearchError) in try SearchCursor(step, for: query) }
    self.query = query
    self.source = source
    self.readBudget = readBudget
  }

  var root: String { query.root }

  func run() async throws -> SearchPage {
    guard let kind = try await source.kind(root) else { throw SearchError(.notFound, "no such path: \(root)") }
    let invalidStep = SearchError(.invalidStep, "invalid step: it names no entry under \(root)")
    if kind == .directory {
      let resumePath = resume?.path.split(separator: "/", omittingEmptySubsequences: false) ?? []
      guard resume == nil || !resumePath.contains(where: \.isEmpty) else { throw invalidStep }
      _ = try await directory(root, try await ancestorIgnores(), resume: resumePath[...])
    } else {
      guard resume?.path.isEmpty ?? true else { throw invalidStep }
      let name = String(root.split(separator: "/").last ?? "")
      _ = try await leaf(root, kind, subject: name, from: resume)
    }
    return SearchPage(
      hits: hits, cursor: cursor?.encoded(for: query), scanned: scanned, skipped: skips.values.sorted { $0.reason < $1.reason },
    )
  }

  // Each returns false once the page has ended, with `cursor` set.

  /// Walks `directory` a listing page at a time, each no larger than what is
  /// left of the entry budget (and one more, to know where a page ends), so
  /// a page lists a directory once however large it is.
  private func directory(_ directory: String, _ inherited: IgnoreStack, resume: ArraySlice<Substring>) async throws -> Bool {
    let first = resume.first.map(String.init) ?? ""
    guard var listing = try await children(of: directory, from: first) else { return true }
    var ignores = inherited
    if !query.noIgnore, try await holdsIgnoreFile(directory, listing, listedFrom: first), let file = try await ignoreFile(in: directory) {
      ignores.files.append(file)
    }
    var children = listing.children[...]
    var from: SearchCursor?
    if !first.isEmpty, let named = children.first, named.name.utf8.elementsEqual(first.utf8) {
      if resume.count > 1 {
        if named.kind == .directory {
          guard try await self.directory(path(directory, named.name), ignores, resume: resume.dropFirst()) else { return false }
        }
        children = children.dropFirst()
      } else {
        from = self.resume
      }
    }
    while true {
      for child in children {
        guard try await visit(path(directory, child.name), child.kind, ignores, from: from) else { return false }
        from = nil
      }
      guard let next = listing.next else { return true }
      guard let following = try await self.children(of: directory, from: next) else { return true }
      listing = following
      children = listing.children[...]
    }
  }

  /// A listing page as large as what is left of the entry budget, and one
  /// more; nil when the directory cannot be listed.
  private func children(of directory: String, from start: String) async throws -> SearchListing? {
    do {
      return try await source.children(of: directory, from: start, limit: max(0, SearchLimits.pageEntries - scanned) + 1)
    } catch is SearchUnreadable {
      skip(.unreadable, directory)
      return nil
    }
  }

  /// Whether `directory` has a `.gitignore` file: a listing from its first
  /// name that reaches past that name already says.
  private func holdsIgnoreFile(_ directory: String, _ listing: SearchListing, listedFrom start: String) async throws -> Bool {
    let name = ".gitignore"
    let covers = listing.next == nil || listing.children.last.map { !$0.name.utf8.lexicographicallyPrecedes(name.utf8) } ?? false
    if start.isEmpty, covers {
      return listing.children.contains { $0.name == name && $0.kind == .file }
    }
    do {
      return try await source.kind(path(directory, name)) == .file
    } catch is SearchUnreadable {
      skip(.unreadable, path(directory, name))
      return false
    }
  }

  private func visit(_ path: String, _ kind: SearchEntryKind, _ ignores: IgnoreStack, from: SearchCursor?) async throws -> Bool {
    try Task.checkCancellation()
    let relative = relative(path)
    // A page's first entry is always visited; any other only with room for
    // one more read (a chunk, or a `.gitignore`).
    guard scanned < SearchLimits.pageEntries, scanned == 0 || readBytes + SearchLimits.lineBytes <= readBudget else {
      cursor = SearchCursor(path: relative)
      return false
    }
    scanned += 1
    if !query.hidden, source.isHidden(path) {
      skip(.hidden, path)
      return true
    }
    if !query.noIgnore, ignores.ignores(path, isDirectory: kind == .directory) {
      skip(.ignored, path)
      return true
    }
    if kind == .directory { return try await directory(path, ignores, resume: []) }
    return try await leaf(path, kind, subject: relative, from: from)
  }

  private func leaf(_ path: String, _ kind: SearchEntryKind, subject: String, from: SearchCursor?) async throws -> Bool {
    switch matcher {
    case let .find(glob):
      guard glob.matches(subject, isDirectory: false) else { return true }
      return accept(SearchHit(path: path), else: SearchCursor(path: relative(path)))
    case let .grep(regex):
      guard kind == .file else { return true }
      let reader: any SearchReader
      do {
        reader = try await source.open(path)
      } catch is SearchUnreadable {
        skip(.unreadable, path)
        return true
      }
      let result = await outcome { try await self.grep(reader, path, regex, offset: from?.offset ?? 0, line: from?.line ?? 1) }
      await reader.close()
      return try result.get()
    }
  }

  private func grep(_ reader: any SearchReader, _ path: String, _ regex: LineMatcher, offset start: Int, line first: Int) async throws -> Bool {
    let relative = relative(path)
    var offset = start
    var lineStart = start
    var line = first
    var pending: [UInt8] = []
    func matchLine() throws -> Bool {
      var text = pending[...]
      if text.last == UInt8(ascii: "\r") { text = text.dropLast() }
      let decoded = String(decoding: text, as: UTF8.self)
      guard try regex.matches(decoded) else { return true }
      let here = SearchCursor(path: relative, offset: lineStart, line: line)
      return accept(SearchHit(path: path, line: line, text: clamped(decoded)), else: here)
    }
    while true {
      if chunks > 0, readBytes + SearchLimits.lineBytes > readBudget {
        cursor = SearchCursor(path: relative, offset: lineStart, line: line)
        return false
      }
      let chunk: Data
      do {
        chunk = try await reader.read(at: offset, count: SearchLimits.lineBytes)
      } catch is SearchUnreadable {
        skip(.unreadable, path)
        return true
      }
      chunks += 1
      readBytes += chunk.count
      if offset == 0, chunk.contains(0) {
        skip(.binary, path)
        return true
      }
      offset += chunk.count
      var rest = chunk[...]
      while let newline = rest.firstIndex(of: UInt8(ascii: "\n")) {
        pending.append(contentsOf: rest[..<newline])
        if pending.count > SearchLimits.lineBytes {
          skip(.longLine, path)
          return true
        }
        guard try matchLine() else { return false }
        lineStart += pending.count + 1
        line += 1
        pending.removeAll(keepingCapacity: true)
        rest = rest[(newline + 1)...]
      }
      pending.append(contentsOf: rest)
      if pending.count > SearchLimits.lineBytes {
        skip(.longLine, path)
        return true
      }
      if chunk.count < SearchLimits.lineBytes {
        return pending.isEmpty ? true : try matchLine()
      }
    }
  }

  /// Adds a hit unless the page is full; a full page ends at `position`.
  private func accept(_ hit: SearchHit, else position: SearchCursor) -> Bool {
    let cost = jsonLength(hit.path) + (hit.text.map(jsonLength) ?? 0) + 40
    guard hits.count < limit, hits.isEmpty || bytes + cost <= SearchLimits.pageBytes else {
      cursor = position
      return false
    }
    hits.append(hit)
    bytes += cost
    return true
  }

  private func skip(_ reason: SearchSkipReason, _ path: String) {
    if skips[reason] == nil {
      skips[reason] = SearchSkip(reason: reason, count: 1, example: path)
      bytes += jsonLength(path) + 32
    } else {
      skips[reason]!.count += 1
    }
  }

  /// The `.gitignore` files above the root that apply inside it: those from
  /// the nearest ancestor holding `.git` down, none outside a repository.
  /// Every page reads them again, so they get at most
  /// ``SearchLimits/ancestorIgnoreBytes`` of the read budget, the rest left
  /// for the walk; one that would not fit is skipped as unreadable.
  private func ancestorIgnores() async throws -> IgnoreStack {
    guard !query.noIgnore, try await exists(path(root, ".git")) == false else { return IgnoreStack() }
    var ancestors: [String] = []
    var current = root
    while current != "/" {
      current = parent(current)
      ancestors.append(current)
      if try await exists(path(current, ".git")) {
        var stack = IgnoreStack()
        for directory in ancestors.reversed() {
          let ignore = path(directory, ".gitignore")
          guard try await source.kind(ignore) == .file else { continue }
          guard readBytes + SearchLimits.ignoreFileBytes <= SearchLimits.ancestorIgnoreBytes else {
            skip(.unreadable, ignore)
            continue
          }
          if let file = try await ignoreFile(in: directory) { stack.files.append(file) }
        }
        return stack
      }
    }
    return IgnoreStack()
  }

  private func exists(_ path: String) async throws -> Bool {
    do {
      return try await source.kind(path) != nil
    } catch is SearchUnreadable {
      return false
    }
  }

  private func ignoreFile(in directory: String) async throws -> IgnoreFile? {
    let file = path(directory, ".gitignore")
    do {
      let reader = try await source.open(file)
      let result = await outcome { try await reader.read(at: 0, count: SearchLimits.ignoreFileBytes) }
      await reader.close()
      let data = try result.get()
      readBytes += data.count
      guard data.count < SearchLimits.ignoreFileBytes else { throw SearchUnreadable("\(SearchLimits.ignoreFileBytes) bytes or larger") }
      return IgnoreFile(base: directory, text: String(decoding: data, as: UTF8.self))
    } catch is SearchUnreadable {
      skip(.unreadable, file)
      return nil
    }
  }

  private func relative(_ path: String) -> String {
    guard path.utf8.count > root.utf8.count else { return "" }
    return String(decoding: path.utf8.dropFirst(root == "/" ? 1 : root.utf8.count + 1), as: UTF8.self)
  }
}

private func path(_ directory: String, _ name: String) -> String {
  directory == "/" ? "/" + name : directory + "/" + name
}

private func parent(_ path: String) -> String {
  guard let slash = path.utf8.lastIndex(of: UInt8(ascii: "/")), slash != path.utf8.startIndex else { return "/" }
  return String(path[..<slash])
}

/// The line, cut on a scalar boundary past ``SearchLimits/shownLineBytes``.
func clamped(_ line: String) -> String {
  let total = line.utf8.count
  guard total > SearchLimits.shownLineBytes else { return line }
  var kept = 0
  var end = line.unicodeScalars.startIndex
  for scalar in line.unicodeScalars {
    let width = UTF8.width(scalar)
    guard kept + width <= SearchLimits.shownLineBytes else { break }
    kept += width
    end = line.unicodeScalars.index(after: end)
  }
  return String(line.unicodeScalars[..<end]) + "…[line clamped: \(total) bytes]"
}

/// An upper bound on the bytes `text` takes as a JSON string.
func jsonLength(_ text: String) -> Int {
  text.utf8.reduce(2) { length, byte in
    length + (byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "\\") ? 2 : byte < 0x20 ? 6 : 1)
  }
}

private func outcome<Success>(_ body: () async throws -> Success) async -> Result<Success, any Error> {
  do {
    return .success(try await body())
  } catch {
    return .failure(error)
  }
}
