import struct Foundation.Data
import struct Foundation.Date
import MachineContract
import SpaceFS

public struct MachineSeam: Sendable {
  public let vfs: @Sendable (MachineID, VFSOp) async throws -> VFSResult
  public let search: @Sendable (MachineID, SearchQuery) async throws -> SearchResult
  public let attached: @Sendable () async -> Set<MachineID>

  public init(
    vfs: @escaping @Sendable (MachineID, VFSOp) async throws -> VFSResult,
    search: @escaping @Sendable (MachineID, SearchQuery) async throws -> SearchResult,
    attached: @escaping @Sendable () async -> Set<MachineID>,
  ) {
    self.vfs = vfs
    self.search = search
    self.attached = attached
  }
}

struct MachineBackend: SpaceVFS {
  let machine: MachineID
  let seam: MachineSeam

  func read(_ path: String) async throws -> (VersionToken, Data) {
    switch try await seam.vfs(machine, .read(path: path)) {
    case let .file(token, data): return (Wire.token(token), Data(data.bytes))
    case let .error(error): throw machineFailure(error)
    default: throw unexpectedResult("read", path)
    }
  }

  func write(_ path: String, _ data: Data, ifMatch: VersionToken?) async throws -> VersionToken {
    if let parent = parentDirectory(of: path) {
      switch try await seam.vfs(machine, .mkdir(path: parent)) {
      case .ok: break
      case let .error(error): throw machineFailure(error)
      default: throw unexpectedResult("mkdir", parent)
      }
    }
    let op = VFSOp.write(path: path, data: Base64Data([UInt8](data)), ifMatch: ifMatch.map(Wire.string))
    switch try await seam.vfs(machine, op) {
    case let .written(token): return Wire.token(token)
    case let .error(error): throw machineFailure(error, staleOnConflict: true)
    default: throw unexpectedResult("write", path)
    }
  }

  func delete(_ path: String, ifMatch: VersionToken?) async throws {
    switch try await seam.vfs(machine, .rm(path: path, ifMatch: ifMatch.map(Wire.string))) {
    case .ok: return
    case let .error(error): throw machineFailure(error, staleOnConflict: true)
    default: throw unexpectedResult("rm", path)
    }
  }

  func move(_ path: String, to destination: String) async throws {
    switch try await seam.vfs(machine, .mv(from: path, to: destination)) {
    case .ok: return
    case let .error(error): throw machineFailure(error)
    default: throw unexpectedResult("mv", path)
    }
  }

  func list(_ path: String) async throws -> (VersionToken, [Entry]) {
    switch try await seam.vfs(machine, .ls(path: path)) {
    case let .entries(entries): return (VersionToken(Data()), entries.map(entry))
    case let .error(error): throw machineFailure(error)
    default: throw unexpectedResult("ls", path)
    }
  }

  func stat(_ path: String) async throws -> Entry {
    switch try await seam.vfs(machine, .stat(path: path)) {
    case let .entry(found): return entry(found)
    case let .error(error): throw machineFailure(error)
    default: throw unexpectedResult("stat", path)
    }
  }

  private func entry(_ entry: MachineEntry) -> Entry {
    let kind: Entry.Kind = switch entry.kind {
    case .file: .file
    case .directory: .directory
    case .symlink: .symlink
    }
    return Entry(
      name: entry.name,
      kind: kind,
      size: entry.size,
      lineCount: nil,
      token: Wire.token(entry.token),
      mtime: Date(timeIntervalSince1970: entry.mtime),
    )
  }

  private func unexpectedResult(_ op: String, _ path: String) -> ToolRunError {
    .failed(code: .internal, message: "machine returned an unexpected result for \(op) \(path)", hint: nil)
  }
}

func machineFailure(_ error: MachineError, staleOnConflict: Bool = false) -> ToolRunError {
  switch error.code {
  case .notFound:
    .failed(code: .notFound, message: error.message, hint: nil)
  case .conflict:
    .failed(code: .conflict, message: error.message, hint: staleOnConflict ? Wire.staleHint : nil)
  case .invalidArgument:
    .failed(code: .invalidArgument, message: error.message, hint: nil)
  case .tooLarge:
    .failed(code: .unsupported, message: error.message, hint: nil)
  case .machineLost, .execNotFound, .tokenInvalid, .tokenRevoked, .windowExceeded, .protocolViolation, .io:
    .failed(code: .internal, message: error.message, hint: nil)
  }
}

private func parentDirectory(of path: String) -> String? {
  guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return nil }
  return String(path[..<slash])
}
