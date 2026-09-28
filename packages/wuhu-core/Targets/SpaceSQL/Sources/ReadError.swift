import struct GRDB.DatabaseValue

public enum ReadError: Error, Equatable, Sendable {
  case notReadOnly
  case forbidden(String)
  case unknownRelation(String)
  case tooLarge(byteLimit: Int)
}

public struct ReadRows: Equatable, Sendable {
  public let columns: [String]
  public let decltypes: [String?]
  public let rows: [[DatabaseValue]]
}
