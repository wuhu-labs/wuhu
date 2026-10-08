import struct Foundation.Data
import JSONValue
import SpaceContract
import SpaceCore
import SpaceFS

extension SpaceToolbox {
  static let read = SpaceTool("read", schema: ReadInput.jsonSchema) { (context, input: ReadInput) in
    let target = try context.resolve(input.path, rev: input.rev)
    let (token, data) = try await target.backend.read(target.path)
    var content = try text(data, at: target.path)
    if let lines = input.lines {
      content = slice(content, lines: try lineRange(lines))
    }
    return Wire.object([("token", .string(Wire.string(token))), ("content", .string(content))])
  }

  static let write = SpaceTool("write", schema: WriteInput.jsonSchema) { (context, input: WriteInput) in
    let target = try context.resolve(input.path)
    let token = try await target.backend.write(target.path, Data(input.content.utf8), ifMatch: input.ifMatch.map(Wire.token))
    return Wire.object([("rev", try revField(token, target)), ("token", .string(Wire.string(token)))])
  }

  static let edit = SpaceTool("edit", schema: EditInput.jsonSchema) { (context, input: EditInput) in
    let target = try context.resolve(input.path)
    let (backend, path) = (target.backend, target.path)
    let (token, data) = try await backend.read(path)
    if let ifMatch = input.ifMatch, ifMatch != Wire.string(token) {
      throw ToolRunError.failed(code: .conflict, message: "version mismatch: \(path)", hint: Wire.staleHint)
    }
    var content = try text(data, at: path)
    for (index, op) in input.edits.enumerated() {
      switch TextEdit.apply(content: content, old: op.old, new: op.new) {
      case let .success(edited):
        content = edited
      case .failure(.notFound):
        throw ToolRunError.failed(
          code: .conflict,
          message: "edit \(index + 1) of \(input.edits.count): old text not found in \(path)",
          hint: Wire.staleHint,
        )
      case let .failure(.notUnique(count)):
        let lines = occurrenceLines(in: content, of: op.old)
        let located = lines.isEmpty ? "" : " at lines \(lines.map(String.init).joined(separator: ", "))"
        throw ToolRunError.failed(
          code: .conflict,
          message: "edit \(index + 1) of \(input.edits.count): old text matches \(count) times in \(path)",
          hint: "matches\(located); widen old with surrounding context until it is unique",
        )
      case .failure(.noChange):
        throw ToolRunError.failed(
          code: .invalidArgument,
          message: "edit \(index + 1) of \(input.edits.count): old and new are identical",
          hint: nil,
        )
      }
    }
    let written = try await backend.write(path, Data(content.utf8), ifMatch: token)
    return Wire.object([("rev", try revField(written, target)), ("token", .string(Wire.string(written)))])
  }

  static let rm = SpaceTool("rm", schema: RemoveInput.jsonSchema) { (context, input: RemoveInput) in
    let target = try context.resolve(input.path)
    if let group = target.group { try await context.refuseWrite(context.spacePath(target.path), in: group) }
    do {
      try await target.backend.delete(target.path, ifMatch: input.ifMatch.map(Wire.token))
    } catch SpaceError.versionMismatch {
      let token = try? await target.backend.stat(target.path).token
      throw ToolRunError.failed(code: .conflict, message: "version mismatch: \(input.path)", hint: Wire.staleHint, token: token.map(Wire.string))
    }
    guard target.isSpace, let group = target.group else { return Wire.object([]) }
    let path = target.path
    let entries = try await context.space.history(try context.spacePath(path), in: group)
    guard let last = entries.last else {
      throw ToolRunError.failed(code: .internal, message: "delete left no journal entry for \(path)", hint: nil)
    }
    return Wire.object([("rev", .integer(last.0.value))])
  }

  static let mv = SpaceTool("mv", schema: MoveInput.jsonSchema) { (context, input: MoveInput) in
    let source = try context.resolve(input.from)
    let destination = try context.resolve(input.to)
    // Nothing moves into or out of the binary's files.
    for (address, target) in [(input.from, source), (input.to, destination)] where target.system {
      throw SpaceError.systemReadOnly(address)
    }
    // The space path grammar bans "@" everywhere; rejecting it up front keeps
    // the resolver from silently stripping a trailing @rev off the destination.
    if destination.machine == nil, input.to.contains("@") {
      throw ToolRunError.failed(code: .invalidPath, message: "invalid space path: \(input.to)", hint: nil)
    }
    guard source.machine == destination.machine else {
      throw ToolRunError.failed(code: .invalidArgument, message: "mv cannot cross backends: \(input.from) -> \(input.to)", hint: nil)
    }
    if input.replace == true, source.machine != nil {
      throw ToolRunError.failed(code: .unsupported, message: "mv replace works only on space paths: \(input.to)", hint: nil)
    }
    guard let sourceGroup = source.group, let destinationGroup = destination.group else {
      try await source.backend.move(source.path, to: destination.path)
      return Wire.object([("dangling", .array([]))])
    }
    guard !input.from.contains("@") else {
      throw ToolRunError.failed(code: .invalidPath, message: "invalid space path: \(input.from)", hint: nil)
    }
    let acting = context.principal.group
    try await SpaceView.requireReadable(sourceGroup, by: acting, actor: context.principal.actor, path: source.path, in: context.space)
    try await SpaceView.requireReadable(destinationGroup, by: acting, actor: context.principal.actor, path: destination.path, in: context.space)
    try await context.space.refuseLayerWrite(try context.spacePath(source.path), in: sourceGroup, by: context.principal.actor)
    try await context.space.refuseLayerWrite(try context.spacePath(destination.path), in: destinationGroup, by: context.principal.actor)
    try await context.space.move(
      source.path, in: sourceGroup, to: destination.path, in: destinationGroup, replacing: input.replace == true, acting: acting,
    )
    let (from, to) = (source.path, destination.path)
    let entries = try await context.space.history(try context.spacePath(to), in: destinationGroup)
    guard let last = entries.last else {
      throw ToolRunError.failed(code: .internal, message: "move left no journal entry for \(to)", hint: nil)
    }
    let sources = try await context.space.linkSources(into: from, in: sourceGroup).map { source.rendered($0) }
    return Wire.object([("rev", .integer(last.0.value)), ("dangling", .array(sources.map(JSONValue.string)))])
  }

  static let ls = SpaceTool("ls", schema: ListInput.jsonSchema) { (context, input: ListInput) in
    let target = try context.resolve(input.path, rev: input.rev)
    let (token, listed) = try await target.backend.list(target.path)
    // The system folder and per-user files are the substrate's, not the
    // navigator's: they leave the root listing unless the caller asks for
    // hidden entries.
    let entries = target.isSpace && target.path == "/" && input.hidden != true
      ? listed.filter { !SessionHome.hiddenRootEntries.contains($0.name) }
      : listed
    return Wire.object([("rev", try revField(token, target)), ("entries", .array(entries.map(Wire.entry)))])
  }

  static let stat = SpaceTool("stat", schema: StatInput.jsonSchema) { (context, input: StatInput) in
    let target = try context.resolve(input.path)
    return Wire.entry(try await target.backend.stat(target.path))
  }
}

private func revField(_ token: VersionToken, _ target: SpaceToolContext.Target) throws -> JSONValue? {
  target.isSpace ? .integer(try Wire.rev(token)) : nil
}

// The JSON tool wire is text-only by construction: decoding invalid UTF-8 here
// would hand back replacement characters that round-trip as corruption.
private func text(_ data: Data, at path: String) throws -> String {
  guard let content = String(validating: data, as: UTF8.self) else {
    throw ToolRunError.failed(
      code: .unsupported,
      message: "\(path) is not UTF-8 text",
      hint: "binary content does not fit the JSON tool wire; fetch the bytes instead: wuhu cat \(path) (GET /v1/f\(path))",
    )
  }
  return content
}

private func lineRange(_ spec: String) throws -> ClosedRange<Int> {
  let parts = spec.split(separator: "-")
  guard parts.count == 2, let lower = Int(parts[0]), let upper = Int(parts[1]), lower >= 1, upper >= lower else {
    throw ToolRunError.failed(
      code: .invalidArgument,
      message: "lines must be \"A-B\" with 1 <= A <= B, got \"\(spec)\"",
      hint: nil,
    )
  }
  return lower ... upper
}

private func slice(_ content: String, lines: ClosedRange<Int>) -> String {
  let all = content.split(separator: "\n", omittingEmptySubsequences: false)
  guard lines.lowerBound <= all.count else { return "" }
  return all[(lines.lowerBound - 1) ... (min(lines.upperBound, all.count) - 1)].joined(separator: "\n")
}

private func occurrenceLines(in content: String, of needle: String) -> [Int] {
  func scan(_ haystack: String, _ needle: String) -> [Int] {
    guard !needle.isEmpty else { return [] }
    var lines: [Int] = []
    var from = haystack.startIndex
    while let range = haystack.range(of: needle, range: from ..< haystack.endIndex) {
      lines.append(haystack[..<range.lowerBound].count(where: { $0 == "\n" }) + 1)
      from = haystack.index(after: range.lowerBound)
    }
    return lines
  }
  let exact = scan(content, needle)
  if exact.count > 1 { return exact }
  return scan(trimLineEnds(content), trimLineEnds(needle))
}

private func trimLineEnds(_ text: String) -> String {
  text.split(separator: "\n", omittingEmptySubsequences: false)
    .map { line in
      var line = Substring(line)
      while line.last == " " || line.last == "\t" { line = line.dropLast() }
      return String(line)
    }
    .joined(separator: "\n")
}
