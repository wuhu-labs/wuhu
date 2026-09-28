import Foundation
import MachineContract

struct WireFailure: Error {
  let error: MachineError

  init(_ code: MachineErrorCode, _ message: String) {
    error = MachineError(code: code, message: message)
  }
}

enum MachineVFS {
  // A read crosses the wire as one frame; the bound keeps its base64 body
  // safely under the server's 16 MiB WebSocket frame ceiling instead of
  // severing the whole channel on a real socket.
  static let maxReadBytes = VFSDefaults.maxReadBytes

  static func execute(_ op: VFSOp, maxReadBytes: Int = MachineVFS.maxReadBytes) -> VFSResult {
    do {
      switch op {
      case let .stat(path):
        return try .entry(entry: entry(at: path))
      case let .ls(path):
        return try .entries(entries: list(path))
      case .read(let path, nil, nil):
        let found = try entry(at: path)
        guard found.size <= maxReadBytes else {
          throw WireFailure(.tooLarge, "read of \(path) (\(found.size) bytes) exceeds the \(maxReadBytes)-byte wire bound; read it in ranges or stream it through exec")
        }
        let data = try read(path)
        return .file(token: found.token, data: Base64Data([UInt8](data)))
      case let .read(path, offset, length):
        let offset = offset ?? 0
        let found = try entry(at: path)
        let length = length ?? max(found.size - offset, 0)
        guard offset >= 0, length >= 0 else {
          throw WireFailure(.invalidArgument, "read range of \(path) must not be negative: offset \(offset), length \(length)")
        }
        guard length <= maxReadBytes else {
          throw WireFailure(.tooLarge, "read of \(length) bytes from \(path) exceeds the \(maxReadBytes)-byte wire bound")
        }
        let data = try read(path, offset: offset, length: length)
        return .file(token: found.token, data: Base64Data([UInt8](data)))
      case let .write(path, data, ifMatch):
        try check(ifMatch, at: path)
        do {
          try Data(data.bytes).write(to: URL(fileURLWithPath: path))
        } catch {
          throw WireFailure(.io, "write failed: \(path)")
        }
        return try .written(token: entry(at: path).token)
      case let .mkdir(path):
        do {
          try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
          throw WireFailure(.io, "mkdir failed: \(path)")
        }
        return .ok
      case let .rm(path, ifMatch):
        try check(ifMatch, at: path)
        guard FileManager.default.fileExists(atPath: path) || entryExists(path) else {
          throw WireFailure(.notFound, path)
        }
        do {
          try FileManager.default.removeItem(atPath: path)
        } catch {
          throw WireFailure(.io, "rm failed: \(path)")
        }
        return .ok
      case let .mv(from, to):
        guard entryExists(from) else { throw WireFailure(.notFound, from) }
        guard !entryExists(to) else { throw WireFailure(.conflict, "destination exists: \(to)") }
        do {
          try FileManager.default.moveItem(atPath: from, toPath: to)
        } catch {
          throw WireFailure(.io, "mv failed: \(from) -> \(to)")
        }
        return .ok
      }
    } catch let failure as WireFailure {
      return .error(error: failure.error)
    } catch {
      return .error(error: MachineError(code: .io, message: "\(error)"))
    }
  }

  static func entry(at path: String) throws -> MachineEntry {
    let attributes = try attributes(at: path)
    let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return MachineEntry(
      name: URL(fileURLWithPath: path).lastPathComponent,
      kind: kind(of: attributes),
      size: (attributes[.size] as? Int) ?? 0,
      token: token(mtime: mtime),
      mtime: mtime,
    )
  }

  static func token(mtime: Double) -> String {
    String(mtime)
  }

  private static func list(_ path: String) throws -> [MachineEntry] {
    let names: [String]
    do {
      names = try FileManager.default.contentsOfDirectory(atPath: path)
    } catch {
      guard entryExists(path) else { throw WireFailure(.notFound, path) }
      throw WireFailure(.io, "ls failed: \(path)")
    }
    return try names.sorted().map { name in
      try entry(at: path == "/" ? "/\(name)" : "\(path)/\(name)")
    }
  }

  private static func read(_ path: String) throws -> Data {
    do {
      return try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw WireFailure(.io, "read failed: \(path)")
    }
  }

  private static func read(_ path: String, offset: Int, length: Int) throws -> Data {
    guard let handle = FileHandle(forReadingAtPath: path) else {
      throw WireFailure(.io, "read failed: \(path)")
    }
    defer { try? handle.close() }
    do {
      try handle.seek(toOffset: UInt64(offset))
      return try handle.read(upToCount: length) ?? Data()
    } catch {
      throw WireFailure(.io, "read failed: \(path)")
    }
  }

  private static func check(_ ifMatch: String?, at path: String) throws {
    guard let ifMatch else { return }
    guard entryExists(path) else {
      throw WireFailure(.conflict, "ifMatch given but entry missing: \(path)")
    }
    let current = try entry(at: path).token
    guard current == ifMatch else {
      throw WireFailure(.conflict, "token mismatch at \(path): \(current) != \(ifMatch)")
    }
  }

  // lstat semantics: a symlink is reported as itself, never followed.
  private static func attributes(at path: String) throws -> [FileAttributeKey: Any] {
    do {
      return try FileManager.default.attributesOfItem(atPath: path)
    } catch {
      throw WireFailure(.notFound, path)
    }
  }

  private static func entryExists(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path)) != nil
  }

  private static func kind(of attributes: [FileAttributeKey: Any]) -> MachineEntryKind {
    switch attributes[.type] as? FileAttributeType {
    case FileAttributeType.typeDirectory: .directory
    case FileAttributeType.typeSymbolicLink: .symlink
    default: .file
    }
  }
}
