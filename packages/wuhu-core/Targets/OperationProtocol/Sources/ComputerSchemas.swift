import enum JSONValue.JSONValue

public enum ComputerKindSchemas {
  public static let exec = KindDescriptor(
    "exec.v1",
    inputSchema: object([
      "argv": ["type": "array", "minItems": 1, "items": ["type": "string"]],
      "cwd": ["type": "string", "pattern": "^/"], "env": strings, "secretValues": strings,
      "sessionCredential": object(["token": string, "spaceURL": string, "expiresAt": ["type": "number"]], required: ["token", "spaceURL"]),
      "stdin": ["type": "boolean"],
    ], required: ["argv", "cwd", "stdin"]),
    resultSchema:
    object(["termination": ["oneOf": [
      object(["tag": ["const": "exit"], "code": ["type": "integer"]], required: ["tag", "code"]),
      object(["tag": ["const": "signal"], "signal": ["type": "integer"]], required: ["tag", "signal"]),
    ]]], required: ["termination"]),
    inputChannels: [.init("stdin", windowBytes: 64 * 1024)],
    outputChannels: [.init("stdout"), .init("stderr")],
  )
  public static let read = KindDescriptor(
    "read.v1",
    inputSchema:
    object(["path": ["type": "string", "pattern": "^/"], "offset": offset, "length": offset, "ifMatch": string], required: ["path"]),
    resultSchema: object(["version": string, "bytes": offset, "reachedEOF": ["type": "boolean"]], required: ["version", "bytes", "reachedEOF"]),
    outputChannels: [.init("data", windowBytes: OperationLimits.maxFilePieceBytes)],
  )
  /// One page of a find (glob over paths) or grep (ICU regex over lines) under `root`; the result is the whole page. A cursor continues only under the `scope` (the caller's name for this machine) that made it.
  public static let search = KindDescriptor(
    "search.v1",
    inputSchema: object([
      "mode": ["enum": ["find", "grep"]], "pattern": string, "root": ["type": "string", "pattern": "^/"], "scope": string,
      "hidden": ["type": "boolean"], "noIgnore": ["type": "boolean"], "limit": ["type": "integer"], "step": string,
    ], required: ["mode", "pattern", "root", "scope"]),
    resultSchema: object([
      "hits": ["type": "array", "items": object(["path": string, "line": positive, "text": string], required: ["path"])],
      "cursor": string,
      "scanned": ["type": "integer", "minimum": 0],
      "skipped": ["type": "array", "items": object([
        "reason": ["enum": ["hidden", "ignored", "binary", "longLine", "unreadable"]], "count": positive, "example": string,
      ], required: ["reason", "count", "example"])],
    ], required: ["hits", "scanned", "skipped"]),
    deliveryPolicy: .boundedResult,
  )
  public static let stat = KindDescriptor("stat.v1", inputSchema: pathInput, resultSchema: entry, deliveryPolicy: .boundedResult)
  public static let list = KindDescriptor("list.v1", inputSchema: pathInput, resultSchema: object(["count": offset], required: ["count"]), outputChannels: [.init("entries", unit: .records, schema: entry)])
  public static let write = KindDescriptor("write.v1", inputSchema: object(["path": string, "ifMatch": string, "bytes": offset, "digest": string], required: ["path", "bytes", "digest"]), resultSchema: object(["version": string], required: ["version"]), inputChannels: [.init("data", windowBytes: OperationLimits.maxFilePieceBytes)])
  /// A file of unknown length and digest, streamed on `data` into a hidden sibling of `path`; once `data` ends, `commit` carries
  /// the length and sha256 of every byte sent. A match is synced and renamed into place, over an existing file only with
  /// `replace` (`fileUnavailable` with errno EEXIST otherwise, checked at start and at the rename); anything else removes the stage.
  public static let stagedWrite = KindDescriptor(
    "stagedWrite.v1",
    inputSchema: object(["path": ["type": "string", "pattern": "^/"], "replace": ["type": "boolean"], "length": offset], required: ["path", "replace"]),
    resultSchema: object(["version": string], required: ["version"]),
    inputChannels: [
      .init("data", windowBytes: OperationLimits.maxFilePieceBytes),
      .init("commit", unit: .records, windowBytes: 1024, maxRecordBytes: 1024, schema: object(["bytes": offset, "sha256": string], required: ["bytes", "sha256"])),
    ],
  )
  public static let mkdir = KindDescriptor("mkdir.v1", inputSchema: pathInput, resultSchema: object([:], required: []), deliveryPolicy: .boundedResult)
  public static let remove = KindDescriptor("remove.v1", inputSchema: object(["path": string, "ifMatch": string], required: ["path"]), resultSchema: object([:], required: []), deliveryPolicy: .boundedResult)
  public static let move = KindDescriptor("move.v1", inputSchema: object(["from": string, "to": string], required: ["from", "to"]), resultSchema: object([:], required: []), deliveryPolicy: .boundedResult)
  private static let pathInput = object(["path": string], required: ["path"])
  private static let entry = object(["name": string, "kind": ["enum": ["file", "directory", "symlink"]], "size": ["type": "integer", "minimum": 0], "token": string, "mtime": ["type": "number"]], required: ["name", "kind", "size", "token", "mtime"])
  private static let string: JSONValue = ["type": "string"]
  private static let strings: JSONValue = ["type": "object", "additionalProperties": ["type": "string"]]
  private static let offset: JSONValue = ["type": "string", "pattern": "^[0-9]+$"]
  private static let positive: JSONValue = ["type": "integer", "minimum": 1]
  private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
    [
      "type": "object",
      "properties": .object(.init(uniqueKeysWithValues: properties.map { ($0.key, $0.value) })),
      "required": .array(required.map(JSONValue.string)),
      "additionalProperties": false,
    ]
  }
}
