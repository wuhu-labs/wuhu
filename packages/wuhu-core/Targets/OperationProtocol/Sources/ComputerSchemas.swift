import enum JSONValue.JSONValue

public enum ComputerKindSchemas {
  public static let exec = KindDescriptor(
    "exec.v1",
    inputSchema: object([
      "argv": ["type": "array", "minItems": 1, "items": ["type": "string"]],
      "cwd": ["type": "string", "pattern": "^/"], "env": strings, "secretValues": strings,
      "sessionCredential": object(["token": string, "spaceURL": string], required: ["token", "spaceURL"]),
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
    outputChannels: [.init("data")],
  )
  public static let find = KindDescriptor(
    "find.v1",
    inputSchema:
    object([
      "root": ["type": "string", "pattern": "^/"],
      "glob": string,
      "includeSymlinks": ["type": "boolean"],
      "entryLimit": positive,
    ], required: ["root", "glob", "includeSymlinks"]),
    resultSchema: counts,
    outputChannels: [.init("entries", unit: .records, schema: object(["path": string, "kind": string], required: ["path", "kind"]))],
  )
  public static let grep = KindDescriptor(
    "grep.v1",
    inputSchema:
    object(
      [
        "root": ["type": "string", "pattern": "^/"],
        "pattern": string,
        "dialect": ["enum": ["literal"]],
        "maxLineBytes": ["type": "integer", "minimum": 1, "maximum": 65536],
        "entryLimit": positive,
      ],
      required: ["root", "pattern", "dialect", "maxLineBytes"],
    ),
    resultSchema: counts,
    outputChannels: [.init("matches", unit: .records, schema: object(["path": string, "line": offset, "text": string], required: ["path", "line", "text"]))],
  )
  private static let string: JSONValue = ["type": "string"]
  private static let strings: JSONValue = ["type": "object", "additionalProperties": ["type": "string"]]
  private static let offset: JSONValue = ["type": "string", "pattern": "^[0-9]+$"]
  private static let positive: JSONValue = ["type": "integer", "minimum": 1]
  private static let counts = object(["scanned": offset, "matched": offset, "skipped": ["type": "object", "additionalProperties": ["type": "integer", "minimum": 0]]], required: ["scanned", "matched", "skipped"])
  private static func object(_ properties: [String: JSONValue], required: [String]) -> JSONValue {
    [
      "type": "object",
      "properties": .object(.init(uniqueKeysWithValues: properties.map { ($0.key, $0.value) })),
      "required": .array(required.map(JSONValue.string)),
      "additionalProperties": false,
    ]
  }
}
