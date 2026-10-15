import enum SpaceCore.SpaceError
import struct WorkerProtocol.WorkerProtocolError

struct SpaceFailureSnapshot: Codable, Sendable {
  let kind: String
  let fields: [String]
  let number: Int?
  init(_ error: SpaceError) {
    switch error {
    case let .notFound(value): kind = "notFound"; fields = [value]; number = nil
    case let .notAFile(value): kind = "notAFile"; fields = [value]; number = nil
    case let .notATable(value): kind = "notATable"; fields = [value]; number = nil
    case let .notADirectory(value): kind = "notADirectory"; fields = [value]; number = nil
    case let .pathIsDirectory(value): kind = "pathIsDirectory"; fields = [value]; number = nil
    case let .alreadyExists(value): kind = "alreadyExists"; fields = [value]; number = nil
    case let .malformedPubkey(value): kind = "malformedPubkey"; fields = [value]; number = nil
    case let .versionMismatch(value): kind = "versionMismatch"; fields = [value]; number = nil
    case let .columnCountMismatch(value): kind = "columnCountMismatch"; fields = [value]; number = nil
    case let .columnTypeChanged(value): kind = "columnTypeChanged"; fields = [value]; number = nil
    case let .invalidTableHeader(value): kind = "invalidTableHeader"; fields = [value]; number = nil
    case let .invalidCellValue(value): kind = "invalidCellValue"; fields = [value]; number = nil
    case let .reservedTablePath(value): kind = "reservedTablePath"; fields = [value]; number = nil
    case let .reservedAccountName(value): kind = "reservedAccountName"; fields = [value]; number = nil
    case let .lastAdmin(value): kind = "lastAdmin"; fields = [value]; number = nil
    case let .readOnlyView(value): kind = "readOnlyView"; fields = [value]; number = nil
    case let .systemReadOnly(value): kind = "systemReadOnly"; fields = [value]; number = nil
    case let .queryForbiddenTable(value): kind = "queryForbiddenTable"; fields = [value]; number = nil
    case let .unknownRelation(value): kind = "unknownRelation"; fields = [value]; number = nil
    case let .templateInvalid(value): kind = "templateInvalid"; fields = [value]; number = nil
    case let .importInvalid(value): kind = "importInvalid"; fields = [value]; number = nil
    case let .vocabularyFrozen(value): kind = "vocabularyFrozen"; fields = [value]; number = nil
    case let .invalidHandle(value): kind = "invalidHandle"; fields = [value]; number = nil
    case let .handleTaken(value): kind = "handleTaken"; fields = [value]; number = nil
    case let .invalidMachineName(value): kind = "invalidMachineName"; fields = [value]; number = nil
    case let .machineNameTaken(value): kind = "machineNameTaken"; fields = [value]; number = nil
    case let .unknownDevice(value): kind = "unknownDevice"; fields = [value]; number = nil
    case let .invalidDeviceKind(value): kind = "invalidDeviceKind"; fields = [value]; number = nil
    case let .needsMigration(value): kind = "needsMigration"; fields = [value]; number = nil
    case let .notAPerson(value): kind = "notAPerson"; fields = [value]; number = nil
    case let .personalGroupEdge(value): kind = "personalGroupEdge"; fields = [value]; number = nil
    case let .groupForbidden(value): kind = "groupForbidden"; fields = [value]; number = nil
    case let .invalidRevision(value): kind = "invalidRevision"; fields = []; number = value
    case let .queryResultTooLarge(value): kind = "queryResultTooLarge"; fields = []; number = value
    case let .listingResultTooLarge(value): kind = "listingResultTooLarge"; fields = []; number = value
    case .queryNotReadOnly: kind = "queryNotReadOnly"; fields = []; number = nil
    case let .foreignHome(path, owner): kind = "foreignHome"; fields = [path, owner]; number = nil
    case let .layerForbidden(path, group): kind = "layerForbidden"; fields = [path, group]; number = nil
    case let .adminThroughGroup(account, groups): kind = "adminThroughGroup"; fields = [account] + groups; number = nil
    }
  }

  func error() throws -> SpaceError {
    switch (kind, fields.count) {
    case ("notFound", 1) where number == nil: return .notFound(fields[0])
    case ("notAFile", 1) where number == nil: return .notAFile(fields[0])
    case ("notATable", 1) where number == nil: return .notATable(fields[0])
    case ("notADirectory", 1) where number == nil: return .notADirectory(fields[0])
    case ("pathIsDirectory", 1) where number == nil: return .pathIsDirectory(fields[0])
    case ("alreadyExists", 1) where number == nil: return .alreadyExists(fields[0])
    case ("malformedPubkey", 1) where number == nil: return .malformedPubkey(fields[0])
    case ("versionMismatch", 1) where number == nil: return .versionMismatch(fields[0])
    case ("columnCountMismatch", 1) where number == nil: return .columnCountMismatch(fields[0])
    case ("columnTypeChanged", 1) where number == nil: return .columnTypeChanged(fields[0])
    case ("invalidTableHeader", 1) where number == nil: return .invalidTableHeader(fields[0])
    case ("invalidCellValue", 1) where number == nil: return .invalidCellValue(fields[0])
    case ("reservedTablePath", 1) where number == nil: return .reservedTablePath(fields[0])
    case ("reservedAccountName", 1) where number == nil: return .reservedAccountName(fields[0])
    case ("lastAdmin", 1) where number == nil: return .lastAdmin(fields[0])
    case ("readOnlyView", 1) where number == nil: return .readOnlyView(fields[0])
    case ("systemReadOnly", 1) where number == nil: return .systemReadOnly(fields[0])
    case ("queryForbiddenTable", 1) where number == nil: return .queryForbiddenTable(fields[0])
    case ("unknownRelation", 1) where number == nil: return .unknownRelation(fields[0])
    case ("templateInvalid", 1) where number == nil: return .templateInvalid(fields[0])
    case ("importInvalid", 1) where number == nil: return .importInvalid(fields[0])
    case ("vocabularyFrozen", 1) where number == nil: return .vocabularyFrozen(fields[0])
    case ("invalidHandle", 1) where number == nil: return .invalidHandle(fields[0])
    case ("handleTaken", 1) where number == nil: return .handleTaken(fields[0])
    case ("invalidMachineName", 1) where number == nil: return .invalidMachineName(fields[0])
    case ("machineNameTaken", 1) where number == nil: return .machineNameTaken(fields[0])
    case ("unknownDevice", 1) where number == nil: return .unknownDevice(fields[0])
    case ("invalidDeviceKind", 1) where number == nil: return .invalidDeviceKind(fields[0])
    case ("needsMigration", 1) where number == nil: return .needsMigration(fields[0])
    case ("notAPerson", 1) where number == nil: return .notAPerson(fields[0])
    case ("personalGroupEdge", 1) where number == nil: return .personalGroupEdge(fields[0])
    case ("groupForbidden", 1) where number == nil: return .groupForbidden(fields[0])
    case ("invalidRevision", 0): if let number { return .invalidRevision(number) }
    case ("queryResultTooLarge", 0): if let number { return .queryResultTooLarge(byteLimit: number) }
    case ("listingResultTooLarge", 0): if let number { return .listingResultTooLarge(byteLimit: number) }
    case ("queryNotReadOnly", 0) where number == nil: return .queryNotReadOnly
    case ("foreignHome", 2) where number == nil: return .foreignHome(path: fields[0], owner: fields[1])
    case ("layerForbidden", 2) where number == nil: return .layerForbidden(path: fields[0], group: fields[1])
    case ("adminThroughGroup", _) where !fields.isEmpty && number == nil: return .adminThroughGroup(account: fields[0], groups: Array(fields.dropFirst()))
    default: break
    }
    throw WorkerProtocolError(.invalidMessage, message: "Invalid space failure snapshot")
  }
}
