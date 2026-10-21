import struct FileSearch.SearchPage
import struct FileSearch.SearchQuery
import struct Foundation.Data
import struct Foundation.Date
import MachineContract
import struct SessionDomain.SessionID
import SpaceFS

public struct MachineSeam: Sendable {
  public let vfs: @Sendable (MachineID, VFSOp) async throws -> VFSResult
  public let search: @Sendable (MachineID, SearchQuery) async throws -> SearchPage
  public let attached: @Sendable () async -> Set<MachineID>

  public init(
    vfs: @escaping @Sendable (MachineID, VFSOp) async throws -> VFSResult,
    search: @escaping @Sendable (MachineID, SearchQuery) async throws -> SearchPage,
    attached: @escaping @Sendable () async -> Set<MachineID>,
  ) {
    self.vfs = vfs
    self.search = search
    self.attached = attached
  }

  /// The session a machine call is made for, so the server can attribute the machine start (`StartRequest.caller`).
  /// Set by the tool executor around each tool call and by `attributed(to:)`; nil for calls no session made.
  @TaskLocal public static var caller: SessionID?

  /// This seam with every file and search call attributed to `session`, however many wrappers sit underneath.
  public func attributed(to session: SessionID) -> MachineSeam {
    MachineSeam(
      vfs: { machine, op in try await Self.$caller.withValue(session) { try await vfs(machine, op) } },
      search: { machine, query in try await Self.$caller.withValue(session) { try await search(machine, query) } },
      attached: attached,
    )
  }

  /// A file bigger than the bound its reader stated.
  public struct OverLimit: Error {
    public let path: String
    public let size: Int
    public let limit: Int
  }

  /// The whole file at `path` with the token it was read at, when it is at
  /// most `limit` bytes; a bigger one is `OverLimit`, found after at most one
  /// frame, so the server never holds more than the bound. One frame when the
  /// file fits, else ranges checked against one stat, so a file that changes
  /// mid-read is refused rather than spliced. An agent built before ranged
  /// reads ignores the range and refuses a file over one frame as tooLarge,
  /// which is how it is told apart.
  public func fileBytes(_ machine: MachineID, _ path: String, limit: Int) async throws -> (token: String, bytes: [UInt8]) {
    switch try await vfs(machine, .read(path: path)) {
    case let .file(token, data):
      guard data.bytes.count <= limit else { throw OverLimit(path: path, size: data.bytes.count, limit: limit) }
      return (token, data.bytes)
    case let .error(error) where error.code == .tooLarge: break
    case let .error(error): throw machineFailure(error)
    default: throw unexpectedResult("read", path)
    }
    let entry: MachineEntry
    switch try await vfs(machine, .stat(path: path)) {
    case let .entry(found): entry = found
    case let .error(error): throw machineFailure(error)
    default: throw unexpectedResult("stat", path)
    }
    guard entry.size <= limit else { throw OverLimit(path: path, size: entry.size, limit: limit) }
    let changed = ToolRunError.failed(code: .conflict, message: "\(path) changed while it was being read", hint: "send it again")
    var bytes: [UInt8] = []
    bytes.reserveCapacity(entry.size)
    while bytes.count < entry.size {
      let length = min(VFSDefaults.maxReadBytes, entry.size - bytes.count)
      switch try await vfs(machine, .read(path: path, offset: bytes.count, length: length)) {
      case let .file(token, data):
        guard token == entry.token, data.bytes.count == length else { throw changed }
        bytes += data.bytes
      case let .error(error) where error.code == .tooLarge:
        throw ToolRunError.failed(
          code: .unsupported,
          message: "\(path) is \(entry.size) bytes and the machine agent there reads at most \(VFSDefaults.maxReadBytes) bytes of a file",
          hint: "upgrade the machine agent to read files over \(VFSDefaults.maxReadBytes >> 20) MiB",
        )
      case let .error(error): throw machineFailure(error)
      default: throw unexpectedResult("read", path)
      }
    }
    // An agent built before ranged reads answers every range with the whole
    // file, and does so only once the file fits one frame. A file that shrank
    // to exactly one frame while keeping its mtime passes every check above;
    // only its size after the read tells.
    guard bytes.count == entry.size, case let .entry(after) = try await vfs(machine, .stat(path: path)),
          after.size == entry.size, after.token == entry.token else { throw changed }
    return (entry.token, bytes)
  }
}

struct MachineBackend: SpaceVFS {
  let machine: MachineID
  let seam: MachineSeam

  /// A machine file is read whole up to one frame, as the tools always did;
  /// a reader with a bigger bound (an image, an attachment, a capability
  /// input) states it to the seam itself.
  func read(_ path: String) async throws -> (VersionToken, Data) {
    do {
      let (token, bytes) = try await seam.fileBytes(machine, path, limit: VFSDefaults.maxReadBytes)
      return (Wire.token(token), Data(bytes))
    } catch let over as MachineSeam.OverLimit {
      throw ToolRunError.failed(
        code: .unsupported,
        message: "\(path) is \(over.size) bytes; a machine file is read whole up to \(over.limit) bytes",
        hint: "read a slice of it with exec (head, tail, sed -n, dd)",
      )
    }
  }

  /// Search, the one streaming reader, runs on the machine itself
  /// (`search.v1`) and never comes here.
  func reader(_ path: String) async throws -> any SpaceFileReader {
    SpaceDataReader(try await read(path).1)
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
}

private func unexpectedResult(_ op: String, _ path: String) -> ToolRunError {
  .failed(code: .internal, message: "machine returned an unexpected result for \(op) \(path)", hint: nil)
}

public func machineFailure(_ error: MachineError, staleOnConflict: Bool = false) -> ToolRunError {
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
