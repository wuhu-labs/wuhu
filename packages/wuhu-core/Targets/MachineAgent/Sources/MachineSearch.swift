import Foundation
import MachineContract
import enum SpaceFS.Glob

enum MachineSearch {
  static func execute(_ query: SearchQuery) -> SearchResult {
    do {
      switch query {
      case let .grep(pattern, path, matchLimit, entryLimit, step):
        return try grep(pattern: pattern, root: path ?? "/", matchLimit: matchLimit, entryLimit: entryLimit, step: step)
      case let .find(glob, path, matchLimit, entryLimit, step):
        return try find(glob: glob, root: path ?? "/", matchLimit: matchLimit, entryLimit: entryLimit, step: step)
      }
    } catch let failure as WireFailure {
      return .error(error: failure.error)
    } catch {
      return .error(error: MachineError(code: .io, message: "\(error)"))
    }
  }

  // Mirrors SpaceTools.grep: same defaults, same regex dialect, same
  // `line@path` cursor, same scanned/matched accounting. M5 asserts parity.
  private static func grep(pattern: String, root: String, matchLimit: Int?, entryLimit: Int?, step: String?) throws -> SearchResult {
    let matchLimit = try positiveLimit(matchLimit, name: "matchLimit", default: 50)
    let entryLimit = try positiveLimit(entryLimit, name: "entryLimit", default: 1000)
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      throw WireFailure(.invalidArgument, "invalid pattern: \(pattern)")
    }
    let cursor = try step.map(GrepCursor.init(step:))

    var matches: [SearchMatch] = []
    var scanned = 0
    var next: GrepCursor?
    try traverse(root: root, resumeAt: cursor?.path, includeSymlinks: false) { file in
      if scanned == entryLimit {
        next = GrepCursor(path: file, line: 1)
        return .stop
      }
      scanned += 1
      let startLine = (file == cursor?.path) ? cursor!.line : 1
      let data: Data
      do {
        data = try Data(contentsOf: URL(fileURLWithPath: file))
      } catch {
        throw WireFailure(.io, "read failed: \(file)")
      }
      let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() where index + 1 >= startLine {
        let text = String(line)
        guard regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
        if matches.count == matchLimit {
          next = GrepCursor(path: file, line: index + 1)
          return .stop
        }
        matches.append(SearchMatch(path: file, line: index + 1, text: text, context: []))
      }
      return .proceed
    }
    return .matches(matches: matches, cursor: next?.encoded)
  }

  private static func find(glob: String, root: String, matchLimit: Int?, entryLimit: Int?, step: String?) throws -> SearchResult {
    let matchLimit = try positiveLimit(matchLimit, name: "matchLimit", default: 50)
    let entryLimit = try positiveLimit(entryLimit, name: "entryLimit", default: 1000)

    var paths: [String] = []
    var scanned = 0
    var next: String?
    try traverse(root: root, resumeAt: step, includeSymlinks: true) { path in
      if scanned == entryLimit {
        next = path
        return .stop
      }
      scanned += 1
      guard Glob.matches(glob, path) else { return .proceed }
      if paths.count == matchLimit {
        next = path
        return .stop
      }
      paths.append(path)
      return .proceed
    }
    return .paths(paths: paths, cursor: next)
  }

  private static func positiveLimit(_ value: Int?, name: String, default defaultValue: Int) throws -> Int {
    guard let value else { return defaultValue }
    guard value >= 1 else {
      throw WireFailure(.invalidArgument, "\(name) must be a positive integer, got \(value)")
    }
    return value
  }
}

// "line@path" parses at the first "@" so the path may contain "@" freely.
private struct GrepCursor {
  let path: String
  let line: Int

  init(path: String, line: Int) {
    self.path = path
    self.line = line
  }

  init(step: String) throws {
    guard let at = step.firstIndex(of: "@"), let line = Int(step[..<at]), line >= 1 else {
      throw WireFailure(.invalidArgument, "invalid grep cursor: \(step)")
    }
    path = String(step[step.index(after: at)...])
    self.line = line
  }

  var encoded: String { "\(line)@\(path)" }
}

enum TraversalVerdict {
  case proceed
  case stop
}

// Leaf paths stream in the lexicographic order of their absolute paths — the
// order a flat `.sorted()` over the whole tree would give — without ever
// materializing the tree: sibling sort keys append "/" to directory names so a
// directory sorts exactly where its descendants' shared prefix does.
func traverse(
  root: String,
  resumeAt: String?,
  includeSymlinks: Bool,
  _ body: (String) throws -> TraversalVerdict,
) throws {
  let attributes: [FileAttributeKey: Any]
  do {
    attributes = try FileManager.default.attributesOfItem(atPath: root)
  } catch {
    throw WireFailure(.notFound, root)
  }
  guard attributes[.type] as? FileAttributeType == FileAttributeType.typeDirectory else {
    if let resumeAt, root < resumeAt { return }
    _ = try body(root)
    return
  }
  _ = try descend(root, resumeAt: resumeAt, includeSymlinks: includeSymlinks, body)
}

private func descend(
  _ directory: String,
  resumeAt: String?,
  includeSymlinks: Bool,
  _ body: (String) throws -> TraversalVerdict,
) throws -> TraversalVerdict {
  let names: [String]
  do {
    names = try FileManager.default.contentsOfDirectory(atPath: directory)
  } catch {
    throw WireFailure(.io, "ls failed: \(directory)")
  }
  let children = names.compactMap { name -> (key: String, path: String, type: FileAttributeType)? in
    let path = directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else {
      return nil
    }
    return (key: type == .typeDirectory ? name + "/" : name, path: path, type: type)
  }.sorted { $0.key < $1.key }
  for child in children {
    switch child.type {
    case FileAttributeType.typeDirectory:
      if let resumeAt, child.path < resumeAt, !resumeAt.hasPrefix(child.path + "/") { continue }
      if try descend(child.path, resumeAt: resumeAt, includeSymlinks: includeSymlinks, body) == .stop { return .stop }
    case FileAttributeType.typeSymbolicLink:
      guard includeSymlinks else { continue }
      if let resumeAt, child.path < resumeAt { continue }
      if try body(child.path) == .stop { return .stop }
    default:
      if let resumeAt, child.path < resumeAt { continue }
      if try body(child.path) == .stop { return .stop }
    }
  }
  return .proceed
}
