import enum DocIndex.FrontmatterError
import struct Foundation.Data
import JSONValue
import OrderedCollections
import SpaceContract
import SpaceCore
import SpaceFS

public enum Wire {
  static let staleHint = "changed since you read it — re-read"

  static func token(_ raw: String) -> VersionToken {
    VersionToken(Data(raw.utf8))
  }

  static func string(_ token: VersionToken) -> String {
    String(decoding: token.bytes, as: UTF8.self)
  }

  static func rev(_ token: VersionToken) throws -> Int {
    guard let value = Int(string(token)) else {
      throw ToolRunError.failed(code: .internal, message: "backend minted a non-revision token", hint: nil)
    }
    return value
  }

  static func object(_ pairs: [(String, JSONValue?)]) -> JSONValue {
    var fields: OrderedDictionary<String, JSONValue> = [:]
    for (name, value) in pairs {
      if let value { fields[name] = value }
    }
    return .object(fields)
  }

  static func toolError(code: ErrorCode, message: String, hint: String?, token: String? = nil) -> JSONValue {
    object([
      ("code", .string(code.rawValue)), ("message", .string(message)), ("hint", hint.map(JSONValue.string)),
      ("token", token.map(JSONValue.string)),
    ])
  }

  static func entry(_ entry: SpaceFS.Entry) -> JSONValue {
    let kind: EntryKind = switch entry.kind {
    case .file: .file
    case .directory: .directory
    case .table: .table
    case .symlink: .symlink
    }
    return object([
      ("name", .string(entry.name)),
      ("kind", .string(kind.rawValue)),
      ("size", .integer(entry.size)),
      ("lineCount", entry.lineCount.map(JSONValue.integer)),
      ("token", .string(string(entry.token))),
      ("mtime", .number(entry.mtime.timeIntervalSince1970)),
    ])
  }

  // Rehydration by declared column type (SPEC.md): a json column's stored
  // canonical JSON parses back to its value, a boolean column's 0/1 becomes
  // true/false. Expression columns carry no decltype and keep storage class.
  static func cell(_ cell: Cell, decltype: String?) -> JSONValue {
    switch (decltype, cell) {
    case let ("JSON_TEXT", .text(stored)):
      guard let value = JSONValue.parse(stored) else {
        return .string(stored)
      }
      return value
    case let ("BOOLEAN", .integer(flag)):
      return .bool(flag != 0)
    case (_, .null): return .null
    case let (_, .integer(value)): return .integer(Int(value))
    case let (_, .real(value)): return .number(value)
    case let (_, .text(value)): return .string(value)
    case let (_, .blob(bytes)): return .string(Data(bytes).base64EncodedString())
    }
  }

  public static func queryOutput(_ rows: Rows) -> JSONValue {
    object([
      ("columns", .array(rows.columns.map(JSONValue.string))),
      ("rows", .array(rows.rows.map { row in
        .array(zip(row, rows.decltypes).map { cell($0, decltype: $1) })
      })),
    ])
  }

  // The typed rule: a json column's value arrives as {"json": v} so a
  // stored JSON string never reads as text, a blob as {"blob": base64}, a
  // boolean column as true/false; expression columns keep their storage class.
  static func typedCell(_ cell: Cell, decltype: String?) -> JSONValue {
    switch (decltype, cell) {
    case (_, .null): .null
    case let ("JSON_TEXT", .text(stored)): .object(["json": JSONValue.parse(stored) ?? .string(stored)])
    case let ("BOOLEAN", .integer(flag)): .bool(flag != 0)
    case let (_, .blob(bytes)): .object(["blob": .string(Data(bytes).base64EncodedString())])
    case let (_, .integer(value)): .integer(Int(value))
    case let (_, .real(value)): .number(value)
    case let (_, .text(value)): .string(value)
    }
  }

  /// A snapshot in the typed rule: `{columns, rows}`, each cell a scalar,
  /// `{"blob": base64}` or `{"json": value}`.
  public static func typedQueryOutput(_ rows: Rows) -> JSONValue {
    object([
      ("columns", .array(rows.columns.map(JSONValue.string))),
      ("rows", .array(rows.rows.map { row in
        .array(zip(row, rows.decltypes).map { typedCell($0, decltype: $1) })
      })),
    ])
  }

  public static func failure(_ error: any Error) -> ToolRunError {
    if let error = error as? ToolRunError { return error }
    if let error = error as? SpaceError { return failure(error) }
    if let error = error as? FrontmatterError {
      return switch error {
      case let .malformed(detail): .failed(code: .invalidArgument, message: "malformed frontmatter: \(detail)", hint: nil)
      case let .unsupported(detail):
        .failed(
          code: .unsupported, message: "this frontmatter cannot be patched safely: \(detail)",
          hint: "edit the file itself; the patch never rewrites what it cannot keep",
        )
      case let .invalid(detail): .failed(code: .invalidArgument, message: detail, hint: nil)
      }
    }
    if let error = error as? SpacePathError {
      return .failed(code: .invalidPath, message: "\(error)", hint: nil)
    }
    if let error = error as? FSResolveError {
      return switch error {
      case .invalidAddress, .unsupportedHost:
        .failed(code: .invalidPath, message: "\(error)", hint: nil)
      case .machineRevision:
        .failed(code: .unsupported, message: "\(error)", hint: nil)
      }
    }
    return .failed(code: .internal, message: "\(error)", hint: nil)
  }

  static func failure(_ error: SpaceError) -> ToolRunError {
    switch error {
    case let .notFound(path):
      .failed(code: .notFound, message: "not found: \(path)", hint: nil)
    case let .unknownRelation(name):
      .failed(code: .notFound, message: "no such table: \(name)", hint: nil)
    case let .versionMismatch(path):
      .failed(code: .conflict, message: "version mismatch: \(path)", hint: staleHint)
    case let .alreadyExists(path):
      .failed(code: .conflict, message: "already exists: \(path)", hint: nil)
    case let .malformedPubkey(pubkey):
      .failed(code: .invalidArgument, message: "malformed pubkey: \(pubkey)", hint: "expected ed25519:<base64 raw key> or p256:<base64 x963 key>")
    case let .readOnlyView(path):
      .failed(code: .unsupported, message: "historical views are read-only: \(path)", hint: nil)
    case let .systemReadOnly(path):
      .failed(
        code: .unsupported,
        message: "wuhu://system/ is read-only: \(path)",
        hint: "it ships with the server; a skill with the same name in the space or your home replaces a system one",
      )
    case let .foreignHome(path, owner):
      .failed(
        code: .unauthorized,
        message: "\(path) is in the home of session \(owner); only \(owner) itself and humans write there",
        hint: "propose the change to \(owner) by message instead",
      )
    case let .notATable(target):
      .failed(
        code: .invalidArgument,
        message: "not a table: \(target)",
        hint: target.hasSuffix(".table")
          ? "no table lives at this path now: it was moved or deleted, or never created"
          : "table paths end with .table",
      )
    case let .vocabularyFrozen(digest):
      .failed(code: .internal, message: "allocation vocabulary diverges from frozen digest \(digest)", hint: nil)
    case let .queryForbiddenTable(table):
      .failed(code: .invalidArgument, message: "table not queryable: \(table)", hint: nil)
    case let .listingResultTooLarge(byteLimit):
      .failed(code: .invalidArgument, message: "listing exceeds \(byteLimit) byte allowance", hint: "List a narrower directory.")
    case let .queryResultTooLarge(byteLimit):
      .failed(
        code: .invalidArgument,
        message: "query result exceeds \(byteLimit >> 20) MB",
        hint: "narrow the query: select fewer columns, filter, or add a LIMIT",
      )
    case let .reservedAccountName(name):
      .failed(code: .invalidArgument, message: "reserved account name: \(name)", hint: nil)
    case let .lastAdmin(account):
      .failed(code: .conflict, message: "\(account) is the last admin; the space must keep one", hint: nil)
    case let .handleTaken(handle):
      .failed(code: .conflict, message: "handle @\(handle) is already taken", hint: nil)
    case let .machineNameTaken(name):
      .failed(code: .conflict, message: "machine name \(name) is already taken", hint: nil)
    case let .unknownDevice(device):
      .failed(code: .notFound, message: "unknown device: \(device)", hint: "list them with: SELECT id, name, kind, machine_id FROM devices")
    case let .needsMigration(compaction):
      .failed(code: .internal, message: "the space database needs the \(compaction) migration", hint: nil)
    case let .adminThroughGroup(account, groups):
      .failed(code: .conflict, message: adminThroughGroupMessage(account, groups), hint: nil)
    case let .notAPerson(account):
      .failed(code: .invalidArgument, message: "\(account) is not a human account; only a person is an admin", hint: nil)
    case let .groupForbidden(group):
      .failed(code: .unauthorized, message: "groupForbidden: group \(group) is not readable from here", hint: nil)
    case let .invalidCellValue(message):
      .failed(code: .invalidArgument, message: message, hint: nil)
    case let .layerForbidden(path, group):
      .failed(
        code: .unauthorized,
        message: group == GroupID.shared.rawValue
          ? "\(path) is part of the space-wide layer; only an admin of shared writes it"
          : "\(path) is part of group \(group)'s layer; only its members write it",
        hint: group == GroupID.shared.rawValue ? "ask a top-level agent or a human admin of shared to make the change" : nil,
      )
    case .invalidHandle, .invalidMachineName, .invalidDeviceKind, .personalGroupEdge,
         .notAFile, .notADirectory, .pathIsDirectory, .invalidRevision,
         .columnCountMismatch, .columnTypeChanged, .invalidTableHeader, .reservedTablePath,
         .queryNotReadOnly, .templateInvalid, .importInvalid:
      .failed(code: .invalidArgument, message: "\(error)", hint: nil)
    }
  }
}
