import struct Foundation.Data
import JSONValue
import SpaceContract
import SpaceCore
import SpaceFS

extension SpaceToolbox {
  static let sync = SpaceTool("sync", schema: SyncInput.jsonSchema) { (context, input: SyncInput) in
    let live = try context.resolve(input.path)
    guard live.isSpace else {
      throw ToolRunError.failed(
        code: .unsupported,
        message: "sync is available only for revisioned space files: \(input.path)",
        hint: nil,
      )
    }
    let baseRev = try Wire.rev(Wire.token(input.baseToken))
    let historical = try context.resolve(input.path, rev: baseRev)
    let (historicalToken, baseData) = try await historical.backend.read(historical.path)
    guard historicalToken == Wire.token(input.baseToken) else {
      throw ToolRunError.failed(
        code: .conflict,
        message: "baseToken does not identify the loaded version of \(input.path)",
        hint: "re-read the document and retry",
      )
    }
    let base = try syncText(baseData, at: input.path)

    for _ in 0 ..< 4 {
      let (currentToken, currentData) = try await live.backend.read(live.path)
      let current = try syncText(currentData, at: input.path)
      let merge = ThreeWayTextMerge.merge(base: base, local: input.content, remote: current)
      guard case let .merged(content) = merge else {
        return try syncResult("conflict", token: currentToken, content: current)
      }
      do {
        let written = try await live.backend.write(live.path, Data(content.utf8), ifMatch: currentToken)
        let kind = current == base || current == input.content ? "saved" : "merged"
        return try syncResult(kind, token: written, content: content)
      } catch SpaceError.versionMismatch {
        continue
      }
    }
    throw ToolRunError.failed(
      code: .conflict,
      message: "\(input.path) kept changing while it was being synchronized",
      hint: "wait for the other writer to settle and retry",
    )
  }
}

private func syncResult(_ kind: String, token: VersionToken, content: String) throws -> JSONValue {
  let raw = Wire.string(token)
  if kind == "conflict" {
    return Wire.object([("kind", .string(kind)), ("token", .string(raw)), ("content", .string(content))])
  }
  return Wire.object([
    ("kind", .string(kind)),
    ("rev", .integer(try Wire.rev(token))),
    ("token", .string(raw)),
    ("content", .string(content)),
  ])
}

private func syncText(_ data: Data, at path: String) throws -> String {
  guard let content = String(validating: data, as: UTF8.self) else {
    throw ToolRunError.failed(code: .unsupported, message: "\(path) is not UTF-8 text", hint: nil)
  }
  return content
}

private enum ThreeWayTextMerge {
  struct Patch: Equatable {
    var range: Range<Int>
    var replacement: [String]
  }

  enum Result: Equatable {
    case merged(String)
    case conflict
  }

  static func merge(base: String, local: String, remote: String) -> Result {
    if local == remote { return .merged(local) }
    if local == base { return .merged(remote) }
    if remote == base { return .merged(local) }

    let baseLines = lines(base)
    let localPatches = patches(from: baseLines, to: lines(local))
    let remotePatches = patches(from: baseLines, to: lines(remote))
    var combined = localPatches
    for remotePatch in remotePatches {
      var duplicate = false
      for localPatch in localPatches where overlaps(localPatch.range, remotePatch.range) {
        guard localPatch == remotePatch else { return .conflict }
        duplicate = true
      }
      if !duplicate { combined.append(remotePatch) }
    }

    combined.sort {
      if $0.range.lowerBound != $1.range.lowerBound {
        return $0.range.lowerBound > $1.range.lowerBound
      }
      return !$0.range.isEmpty && $1.range.isEmpty
    }
    var result = baseLines
    for patch in combined {
      result.replaceSubrange(patch.range, with: patch.replacement)
    }
    return .merged(result.joined(separator: "\n"))
  }

  private static func lines(_ text: String) -> [String] {
    text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }

  private static func patches(from base: [String], to target: [String]) -> [Patch] {
    let difference = target.difference(from: base)
    var removed: Set<Int> = []
    var inserted: Set<Int> = []
    for change in difference {
      switch change {
      case let .remove(offset, _, _): removed.insert(offset)
      case let .insert(offset, _, _): inserted.insert(offset)
      }
    }

    var patches: [Patch] = []
    var baseIndex = 0
    var targetIndex = 0
    while baseIndex < base.count || targetIndex < target.count {
      let baseChanged = baseIndex < base.count && removed.contains(baseIndex)
      let targetChanged = targetIndex < target.count && inserted.contains(targetIndex)
      if !baseChanged, !targetChanged {
        precondition(baseIndex < base.count && targetIndex < target.count && base[baseIndex] == target[targetIndex])
        baseIndex += 1
        targetIndex += 1
        continue
      }

      let start = baseIndex
      var replacement: [String] = []
      while targetIndex < target.count, inserted.contains(targetIndex) {
        replacement.append(target[targetIndex])
        targetIndex += 1
      }
      while baseIndex < base.count, removed.contains(baseIndex) {
        baseIndex += 1
      }
      patches.append(Patch(range: start ..< baseIndex, replacement: replacement))
    }
    return patches
  }

  private static func overlaps(_ lhs: Range<Int>, _ rhs: Range<Int>) -> Bool {
    switch (lhs.isEmpty, rhs.isEmpty) {
    case (true, true):
      lhs.lowerBound == rhs.lowerBound
    case (true, false):
      rhs.lowerBound < lhs.lowerBound && lhs.lowerBound < rhs.upperBound
    case (false, true):
      lhs.lowerBound < rhs.lowerBound && rhs.lowerBound < lhs.upperBound
    case (false, false):
      max(lhs.lowerBound, rhs.lowerBound) < min(lhs.upperBound, rhs.upperBound)
    }
  }
}
