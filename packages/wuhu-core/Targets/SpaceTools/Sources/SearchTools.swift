import Foundation
import JSONValue
import MachineContract
import SpaceContract
import SpaceFS
import SystemFiles

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
            ("text", .string(match.text)),
            ("context", .array(match.context.map(JSONValue.string))),
          ])
        })),
        ("cursor", cursor.map(JSONValue.string)),
      ])
    }
    let matchLimit = try positiveLimit(input.matchLimit, name: "matchLimit", default: 50)
    let entryLimit = try positiveLimit(input.entryLimit, name: "entryLimit", default: 1000)
    let regex: NSRegularExpression
    do {
      regex = try NSRegularExpression(pattern: input.pattern)
    } catch {
      throw ToolRunError.failed(code: .invalidArgument, message: "invalid pattern: \(input.pattern)", hint: nil)
    }
    let cursor = try input.step.map(GrepCursor.init(step:))
    let files = try await leafPaths(target.backend, root: target.path, filesOnly: true)

    var matches: [JSONValue] = []
    var scanned = 0
    var next: GrepCursor?
    scan: for file in files {
      if let cursor, file < cursor.path { continue }
      if scanned == entryLimit {
        next = GrepCursor(path: file, line: 1)
        break
      }
      scanned += 1
      let startLine = (file == cursor?.path) ? cursor!.line : 1
      let (_, data) = try await target.backend.read(file)
      let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() where index + 1 >= startLine {
        let text = String(line)
        guard regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { continue }
        if matches.count == matchLimit {
          next = GrepCursor(path: file, line: index + 1)
          break scan
        }
        matches.append(Wire.object([
          ("path", .string(target.rendered(file))),
          ("line", .integer(index + 1)),
          ("text", .string(text)),
          ("context", .array([])),
        ]))
      }
    }
    return Wire.object([("matches", .array(matches)), ("cursor", next.map { .string($0.encoded) })])
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
    let matchLimit = try positiveLimit(input.matchLimit, name: "matchLimit", default: 50)
    let entryLimit = try positiveLimit(input.entryLimit, name: "entryLimit", default: 1000)
    let leaves = try await leafPaths(target.backend, root: target.path, filesOnly: false)

    var paths: [JSONValue] = []
    var matched = 0
    var scanned = 0
    var next: String?
    for path in leaves {
      if let step = input.step, path < step { continue }
      if scanned == entryLimit {
        next = path
        break
      }
      scanned += 1
      guard Glob.matches(input.glob, path) else { continue }
      if matched == matchLimit {
        next = path
        break
      }
      matched += 1
      paths.append(.string(target.rendered(path)))
    }
    return Wire.object([("paths", .array(paths)), ("cursor", next.map(JSONValue.string))])
  }
}

private func searchFailure(_ result: SearchResult) -> ToolRunError {
  guard case let .error(error) = result else {
    return .failed(code: .internal, message: "machine returned an unexpected search result", hint: nil)
  }
  return machineFailure(error)
}

private func positiveLimit(_ value: Int?, name: String, default defaultValue: Int) throws -> Int {
  guard let value else { return defaultValue }
  guard value >= 1 else {
    throw ToolRunError.failed(code: .invalidArgument, message: "\(name) must be a positive integer, got \(value)", hint: nil)
  }
  return value
}

// "line@path" is parseable in one place only because the path grammar bans "@".
private struct GrepCursor {
  let path: String
  let line: Int

  init(path: String, line: Int) {
    self.path = path
    self.line = line
  }

  init(step: String) throws {
    guard let at = step.firstIndex(of: "@"), let line = Int(step[..<at]), line >= 1 else {
      throw ToolRunError.failed(code: .invalidArgument, message: "invalid grep cursor: \(step)", hint: nil)
    }
    self.path = String(step[step.index(after: at)...])
    self.line = line
  }

  var encoded: String { "\(line)@\(path)" }
}

private func leafPaths(_ backend: any SpaceVFS, root: String, filesOnly: Bool) async throws -> [String] {
  if root != "/" {
    let entry = try await backend.stat(root)
    switch entry.kind {
    case .file: return [root]
    case .table, .symlink: return filesOnly ? [] : [root]
    case .directory: break
    }
  }
  return try await leavesUnder(backend, directory: root, filesOnly: filesOnly).sorted()
}

private func leavesUnder(_ backend: any SpaceVFS, directory: String, filesOnly: Bool) async throws -> [String] {
  var paths: [String] = []
  for entry in try await backend.list(directory).1 {
    let child = directory == "/" ? "/\(entry.name)" : "\(directory)/\(entry.name)"
    switch entry.kind {
    case .directory:
      paths += try await leavesUnder(backend, directory: child, filesOnly: filesOnly)
    case .file:
      paths.append(child)
    case .table, .symlink:
      if !filesOnly { paths.append(child) }
    }
  }
  return paths
}
