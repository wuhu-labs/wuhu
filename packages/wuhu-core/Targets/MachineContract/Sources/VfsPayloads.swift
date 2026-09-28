import Contract
import JSONValue

public enum VFSDefaults {
  public static let maxReadBytes: Int = 8 << 20
}

@Contract
public enum MachineEntryKind: String, Codable, Equatable, Sendable {
  case file
  case directory
  case symlink
}

@Contract
public struct MachineEntry: Codable, Equatable, Sendable {
  public let name: String
  public let kind: MachineEntryKind
  public let size: Int
  public let token: String
  public let mtime: Double
}

@Contract
public enum VFSOp: Codable, Equatable, Sendable {
  case stat(path: String)
  case ls(path: String)
  case read(path: String, offset: Int? = nil, length: Int? = nil)
  case write(path: String, data: Base64Data, ifMatch: String?)
  case mkdir(path: String)
  case rm(path: String, ifMatch: String?)
  case mv(from: String, to: String)
}

@Contract
public struct VFSRequest: Codable, Equatable, Sendable {
  public let id: Int
  public let op: VFSOp
}

@Contract
public enum VFSResult: Codable, Equatable, Sendable {
  case entry(entry: MachineEntry)
  case entries(entries: [MachineEntry])
  case file(token: String, data: Base64Data)
  case written(token: String)
  case ok
  case error(error: MachineError)
}

@Contract
public struct VFSResponse: Codable, Equatable, Sendable {
  public let id: Int
  public let result: VFSResult
}
