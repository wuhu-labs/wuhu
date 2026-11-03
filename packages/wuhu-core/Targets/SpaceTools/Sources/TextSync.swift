import struct Foundation.Data
import JSONValue
import SpaceContract
import SpaceCore
import SpaceFS

extension SpaceToolbox {
  static let sync = SpaceTool("sync", schema: SyncInput.jsonSchema) { (context, input: SyncInput) in
    let live = try await context.resolve(input.path)
    guard live.isSpace else {
      throw ToolRunError.failed(
        code: .unsupported,
        message: "sync is available only for revisioned space files: \(input.path)",
        hint: nil,
      )
    }
    let baseRev = try Wire.rev(Wire.token(input.baseToken))
    let historical = try await context.resolve(input.path, rev: baseRev)
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
