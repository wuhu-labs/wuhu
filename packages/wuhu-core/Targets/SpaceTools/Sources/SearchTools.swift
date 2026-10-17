import Dependencies
import struct FileSearch.SearchChild
import enum FileSearch.SearchEntryKind
import struct FileSearch.SearchError
import struct FileSearch.SearchHit
import struct FileSearch.SearchListing
import struct FileSearch.SearchPage
import struct FileSearch.SearchQuery
import protocol FileSearch.SearchReader
import enum FileSearch.SearchSkipReason
import protocol FileSearch.SearchSource
import struct FileSearch.SearchUnreadable
import Foundation
import JSONValue
import SpaceContract
import struct SpaceCore.SessionHome
import enum SpaceCore.SpaceError
import SpaceFS

// find and grep are one FileSearch query whoever calls them (the tools,
// run_script, pages, anonymous public-read included) and whatever they search:
// the engine walks a space or the system files here, and a machine's disk
// through `search.v1` on the machine itself. Same walk, cursor and bounds
// everywhere (FileSearch SPEC).
extension SpaceToolbox {
  static let grep = SpaceTool("grep", schema: GrepInput.jsonSchema) { (context, input: GrepInput) in
    let target = try context.resolve(input.path ?? "/")
    let query = SearchQuery(
      mode: .grep, pattern: input.pattern, root: target.path, scope: scope(target),
      hidden: input.hidden ?? false, noIgnore: input.noIgnore ?? false, limit: input.matchLimit, step: input.step,
    )
    let page = try await search(query, target, context)
    return rendered(page, target, hits: "matches") { hit in
      Wire.object([
        ("path", .string(rendered(hit.path, target))),
        ("line", .integer(hit.line ?? 0)),
        ("text", .string(hit.text ?? "")),
      ])
    }
  }

  static let find = SpaceTool("find", schema: FindInput.jsonSchema) { (context, input: FindInput) in
    let target = try context.resolve(input.path ?? "/")
    let query = SearchQuery(
      mode: .find, pattern: input.glob, root: target.path, scope: scope(target),
      hidden: input.hidden ?? false, noIgnore: input.noIgnore ?? false, limit: input.matchLimit, step: input.step,
    )
    let page = try await search(query, target, context)
    return rendered(page, target, hits: "paths") { .string(rendered($0.path, target)) }
  }

  /// One page of `query` on `target`'s backend; the search's own failures are tool failures.
  static func search(_ query: SearchQuery, _ target: SpaceToolContext.Target, _ context: SpaceToolContext) async throws -> SearchPage {
    do {
      if let machine = target.machine {
        try query.validate()
        return try await context.machineSearch(machine, query)
      }
      @Dependency(\.continuousClock) var clock
      return try await query.run(in: SpaceSearchSource(backend: target.backend, hidesRootEntries: target.isSpace), clock: clock)
    } catch let error as SearchError {
      throw searchFailure(error)
    }
  }

  /// What a cursor is bound to besides its root: the machine, the group or the system files.
  private static func scope(_ target: SpaceToolContext.Target) -> String {
    if let machine = target.machine { return "machine:\(machine.rawValue)" }
    if let group = target.group { return "space:\(group.rawValue)" }
    return "system"
  }

  private static func rendered(
    _ page: SearchPage, _ target: SpaceToolContext.Target, hits key: String, _ hit: (SearchHit) -> JSONValue,
  ) -> JSONValue {
    Wire.object([
      (key, .array(page.hits.map(hit))),
      ("cursor", page.cursor.map(JSONValue.string)),
      ("scanned", .integer(page.scanned)),
      ("skipped", .array(page.skipped.map { skip in
        Wire.object([
          ("reason", .string(wireReason(skip.reason).rawValue)),
          ("count", .integer(skip.count)),
          ("example", .string(rendered(skip.example, target))),
        ])
      })),
    ])
  }

  private static func wireReason(_ reason: FileSearch.SearchSkipReason) -> SpaceContract.SearchSkipReason {
    switch reason {
    case .hidden: .hidden
    case .ignored: .ignored
    case .binary: .binary
    case .longLine: .longLine
    case .unreadable: .unreadable
    }
  }

  private static func rendered(_ path: String, _ target: SpaceToolContext.Target) -> String {
    target.machine.map { "machines://\($0.rawValue)" + path } ?? target.rendered(path)
  }
}

/// A search's own failure as the tools report it.
public func searchFailure(_ error: SearchError) -> ToolRunError {
  switch error.code {
  case .invalidPattern, .invalidGlob, .invalidStep, .invalidLimit:
    .failed(code: .invalidArgument, message: error.message, hint: nil)
  case .notFound:
    .failed(code: .notFound, message: error.message, hint: nil)
  case .timeout:
    .failed(code: .unavailable, message: error.message, hint: "narrow the path, or simplify the pattern")
  }
}

/// A space view or the system files as the engine walks them. Dot-names are
/// hidden as they are on a machine's disk; at a space's root, so are `/_` and
/// `/users`, as `ls` hides them.
struct SpaceSearchSource: SearchSource {
  let backend: any SpaceVFS
  let hidesRootEntries: Bool

  func kind(_ path: String) async throws -> SearchEntryKind? {
    do {
      // A space's root has no entry of its own to stat; listing it is what
      // refuses a group the caller does not read.
      guard path != "/" else {
        _ = try await backend.list(path, from: "", limit: 1)
        return .directory
      }
      return try await Self.searchKind(backend.stat(path).kind)
    } catch SpaceError.notFound {
      return nil
    }
  }

  func children(of directory: String, from start: String, limit: Int) async throws -> SearchListing {
    do {
      let page = try await backend.list(directory, from: start, limit: limit)
      return SearchListing(children: page.entries.map { SearchChild(name: $0.name, kind: Self.searchKind($0.kind)) }, next: page.next)
    } catch SpaceError.notFound {
      throw SearchUnreadable("gone")
    }
  }

  func open(_ file: String) async throws -> any SearchReader {
    do {
      return try await FileReader(file: backend.reader(file))
    } catch SpaceError.notFound {
      throw SearchUnreadable("gone")
    }
  }

  func isHidden(_ path: String) -> Bool {
    guard let name = path.split(separator: "/").last else { return false }
    if name.hasPrefix(".") { return true }
    return hidesRootEntries && path == "/" + name && SessionHome.hiddenRootEntries.contains(String(name))
  }

  private static func searchKind(_ kind: SpaceFS.Entry.Kind) -> SearchEntryKind {
    switch kind {
    case .directory: .directory
    case .file: .file
    case .table, .symlink: .other
    }
  }
}

private struct FileReader: SearchReader {
  let file: any SpaceFileReader

  func read(at offset: Int, count: Int) async throws -> Data {
    do {
      return try await file.read(at: offset, count: count)
    } catch SpaceError.notFound {
      throw SearchUnreadable("gone")
    }
  }

  func close() async {}
}
