#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import enum JSONValue.JSONValue
import struct MachineContract.MachineEntry
import enum MachineContract.MachineEntryKind
import struct OperationProtocol.OperationError
import Synchronization

extension ComputerFileOperations {
  static var local: Self { local(synchronize: { fd in guard fsync(fd) == 0 else { throw diskError() } }) }
  static func local(synchronize: @escaping @Sendable (Int32) throws -> Void) -> Self {
    .init(stat: { path in try await diskIO { try metadata(path) } }, list: { path in
      let cursor = try await diskIO { _ = try metadata(path); return try MetadataDirectory(path) }
      return .init(next: { try await diskIO { try cursor.next() } }, close: { await diskIO { cursor.close() } })
    }, write: { path, token in
      let writer = try await diskIO { try DiskWriter(path: path, token: token, synchronize: synchronize) }
      return .init(append: { data in try await diskIO { try writer.append(data) } }, prepare: { try await diskIO { try writer.prepare() } }, commit: { try await cancellableDiskIO { check in try writer.commit(check: check) } }, close: { await diskIO { writer.close() } })
    }, mkdir: { path in
      try await cancellableDiskIO { check in
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw diskError() }; defer { closeDescriptor(fd) }
        let parts = path.split(separator: "/")
        for (index, part) in parts.enumerated() {
          try check(); let name = String(part)
          if mkdirat(fd, name, 0o755) != 0 && errno != EEXIST { throw diskError() }
          let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | (index == parts.count - 1 ? O_NOFOLLOW : 0)
          let next = openat(fd, name, flags)
          guard next >= 0 else { throw diskError() }; closeDescriptor(fd); fd = next
        }
      }
    }, remove: { path, token in
      try await cancellableDiskIO { check in
        let parent = try sourceParent(path, token: token); defer { closeDescriptor(parent.fd) }
        try removeAt(parent.fd, parent.name, depth: 0, check: check)
      }
    }, move: { from, to in
      try await diskIO {
        let source = try sourceParent(from, token: nil); defer { closeDescriptor(source.fd) }
        let target = try parentOf(to); defer { closeDescriptor(target.fd) }
        #if os(Linux)
          let result = renameExclusive(source.fd, source.name, target.fd, target.name, 1)
        #else
          let result = renameatx_np(source.fd, source.name, target.fd, target.name, UInt32(RENAME_EXCL))
        #endif
        guard result == 0 else { throw diskError() }
      }
    })
  }
}

#if os(Linux)
  @_silgen_name("renameat2")
  private func renameExclusive(_ oldFD: Int32, _ old: UnsafePointer<CChar>, _ newFD: Int32, _ new: UnsafePointer<CChar>, _ flags: UInt32) -> Int32
#endif

private func parentOf(_ path: String) throws -> (fd: Int32, name: String) {
  let parts = path.split(separator: "/")
  guard let last = parts.last, last != ".", last != "..", !parts.contains("..") else { throw OperationError(.invalidInput) }
  let parent = "/" + parts.dropLast().joined(separator: "/")
  let fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
  guard fd >= 0 else { throw diskError() }
  return (fd, String(last))
}

private func metadata(_ path: String) throws -> MachineEntry {
  if path.split(separator: "/").isEmpty { return try metadataAt(AT_FDCWD, "/") }
  return try fileLookup {
    let parent = try parentOf(path); defer { closeDescriptor(parent.fd) }
    return try metadataAt(parent.fd, parent.name)
  }
}

func fileLookup<T>(_ effect: () throws -> T) throws -> T {
  do { return try effect() }
  catch let error as OperationError where error.code == .fileUnavailable {
    var details: JSONValue = ["lookup": .bool(true)]
    if case var .object(fields)? = error.details { fields["lookup"] = .bool(true); details = .object(fields) }
    throw OperationError(.fileUnavailable, details: details)
  }
}

private func sourceParent(_ path: String, token: String?) throws -> (fd: Int32, name: String) {
  do {
    return try fileLookup {
      let parent = try parentOf(path)
      do { try checkToken(parent.fd, parent.name, token); _ = try metadataAt(parent.fd, parent.name); return parent }
      catch { closeDescriptor(parent.fd); throw error }
    }
  } catch let error as OperationError where error.code == .fileUnavailable && token != nil { throw OperationError(.fileChanged) }
}

private func metadataAt(_ fd: Int32, _ name: String) throws -> MachineEntry {
  var value = stat()
  guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw diskError() }
  let status = statusInfo(value)
  #if os(Linux)
    let mt = value.st_mtim
  #else
    let mt = value.st_mtimespec
  #endif
  return .init(name: name, kind: MachineEntryKind(rawValue: status.kind) ?? .file, size: Int(clamping: status.size), token: status.version, mtime: Double(mt.tv_sec) + Double(mt.tv_nsec) / 1e9)
}

private func checkToken(_ fd: Int32, _ name: String, _ token: String?) throws {
  guard let token else { return }
  guard let current = try? metadataAt(fd, name), current.token == token else { throw OperationError(.fileChanged) }
}

#if os(Linux)
  private typealias MetadataDirectoryPointer = OpaquePointer
#else
  private typealias MetadataDirectoryPointer = UnsafeMutablePointer<DIR>
#endif

private final class MetadataDirectory: Sendable {
  private let directory: Mutex<MetadataDirectoryPointer?>
  init(_ path: String) throws {
    let trimmed = path == "/" ? path : String(path.reversed().drop(while: { $0 == "/" }).reversed())
    let fd = open(trimmed, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw diskError() }
    guard let pointer = fdopendir(fd) else { let error = diskError(); closeDescriptor(fd); throw error }
    directory = Mutex(pointer)
  }

  deinit { close() }
  func close() { directory.withLock { if let p = $0 { closedir(p); $0 = nil } } }
  func next() throws -> MachineEntry? {
    try directory.withLock { pointer in
      guard let pointer else { return nil }
      while true {
        try Task.checkCancellation(); errno = 0
        guard let entry = readdir(pointer) else { if errno != 0 { throw diskError() }; return nil }
        let name = entryName(entry)
        if name == "." || name == ".." { continue }
        return try metadataAt(dirfd(pointer), name)
      }
    }
  }
}

private func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
  withUnsafePointer(to: &entry.pointee.d_name) { pointer in pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) } }
}

private func removeAt(_ parent: Int32, _ name: String, depth: Int, check: @Sendable () throws -> Void) throws {
  try check()
  guard depth < 128 else { throw OperationError(.capacityExceeded) }
  let entry = try metadataAt(parent, name)
  if entry.kind == .directory {
    let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else { throw diskError() }
    guard let directory = fdopendir(fd) else { let error = diskError(); closeDescriptor(fd); throw error }
    defer { closedir(directory) }
    while true {
      try check(); errno = 0
      guard let child = readdir(directory) else { if errno != 0 { throw diskError() }; break }
      let childName = entryName(child)
      if childName != "." && childName != ".." { try removeAt(fd, childName, depth: depth + 1, check: check) }
    }
    guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw diskError() }
  } else { guard unlinkat(parent, name, 0) == 0 else { throw diskError() } }
}

private final class DiskWriter: Sendable {
  private struct State { var fd: Int32; var closed = false; var prepared = false; var committed = false }
  private let state: Mutex<State>
  private let parent: Int32
  private let name: String
  private let temporary: String
  private let token: String?
  private let synchronize: @Sendable (Int32) throws -> Void
  init(path: String, token: String?, synchronize: @escaping @Sendable (Int32) throws -> Void) throws {
    let target = try parentOf(path)
    parent = target.fd; name = target.name; self.token = token; self.synchronize = synchronize
    temporary = ".wuhu-write-" + UUID().uuidString
    do {
      try checkToken(parent, name, token)
      _ = try writableTarget(parent, name)
      let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o666)
      guard fd >= 0 else { throw diskError() }
      state = Mutex(State(fd: fd))
    } catch { closeDescriptor(parent); throw error }
  }

  deinit { close(); closeDescriptor(parent) }
  func append(_ data: Data) throws {
    try state.withLock { state in
      guard !state.closed, !state.prepared else { throw OperationError(.operationEnded) }
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          #if os(Linux)
            let n = Glibc.write(state.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
          #else
            let n = Darwin.write(state.fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
          #endif
          if n < 0 && errno == EINTR { continue }
          guard n > 0 else { throw diskError() }; offset += n
        }
      }
    }
  }

  func prepare() throws {
    try state.withLock { state in
      guard !state.closed, !state.committed else { throw OperationError(.operationEnded) }
      try checkToken(parent, name, token)
      if let original = try writableTarget(parent, name) {
        guard fchmod(state.fd, original.st_mode & 0o7777) == 0 else { throw diskError() }
      }
      try synchronize(state.fd)
      state.prepared = true
    }
  }

  func commit(check: @Sendable () throws -> Void) throws -> String {
    try state.withLock { state in
      guard !state.closed, state.prepared, !state.committed else { throw OperationError(.operationEnded) }
      try checkToken(parent, name, token)
      _ = try writableTarget(parent, name)
      try check()
      guard renameat(parent, temporary, parent, name) == 0 else { throw diskError() }
      state.committed = true
      var value = stat()
      guard fstat(state.fd, &value) == 0 else { preconditionFailure("committed write descriptor became invalid") }
      return statusInfo(value).version
    }
  }

  func close() {
    state.withLock { state in
      if !state.closed { closeDescriptor(state.fd); if !state.committed { _ = unlinkat(parent, temporary, 0) }; state.closed = true }
    }
  }
}

private func writableTarget(_ parent: Int32, _ name: String) throws -> stat? {
  var value = stat()
  if fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
    if errno == ENOENT { return nil }
    throw diskError()
  }
  guard value.st_mode & S_IFMT == S_IFREG else { throw OperationError(.fileUnavailable) }
  let existing = openat(parent, name, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
  guard existing >= 0 else { throw diskError() }
  defer { closeDescriptor(existing) }
  guard fstat(existing, &value) == 0 else { throw diskError() }
  return value
}
