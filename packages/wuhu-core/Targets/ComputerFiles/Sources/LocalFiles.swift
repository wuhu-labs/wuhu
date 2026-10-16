#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import Dispatch
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import struct OperationProtocol.OperationError
import Synchronization

extension ComputerFileSystem {
  public static var local: Self { local() }
  static func local(beforeOpen: @escaping @Sendable (String) throws -> Void = { _ in }, didInspect: @escaping @Sendable (String) -> Void = { _ in }, didYield: @escaping @Sendable (String) throws -> Void = { _ in }) -> Self {
    Self(status: { path in try await diskIO { try fileLookup { try fileStatus(path) } } }, read: { path, offset, count in
      try await diskIO {
        guard count > 0 && count <= 65536, offset <= UInt64(Int64.max) else { throw OperationError(.invalidInput) }
        try beforeOpen(path)
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw diskError() }; defer { closeDescriptor(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw OperationError(.fileUnavailable) }
        let initial = statusInfo(value)
        guard try fileStatus(path) == initial else { throw OperationError(.fileChanged) }
        var bytes = Data(count: count)
        let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard n >= 0 else { throw diskError() }
        var after = stat()
        guard fstat(fd, &after) == 0 else { throw diskError() }
        guard statusInfo(after) == initial, try fileStatus(path) == initial else { throw OperationError(.fileChanged) }
        bytes.removeSubrange(n ..< bytes.count); return bytes
      }
    }, walk: { root, symlinks in
      let trimmed = String(root.reversed().drop(while: { $0 == "/" }).reversed())
      let normalized = trimmed.isEmpty ? "/" : trimmed
      let cursor = DiskWalk(root: normalized, symlinks: symlinks, beforeOpen: beforeOpen, didInspect: didInspect)
      return ComputerWalk(checkedNext: { operationCheck in
        while true {
          try await operationCheck()
          let step = try await cancellableDiskIO { check in try cursor.step(check: check) }
          switch step {
          case .again: continue
          case .end: return nil
          case let .entry(entry): try didYield(entry.path); return entry
          }
        }
      }, close: { await diskIO { cursor.close() } }, skipCounts: { cursor.skipCounts() })
    }, operations: .local)
  }
}

private let diskQueue = DispatchQueue(label: "wuhu.machine-v2.files", attributes: .concurrent)
func diskIO<T: Sendable>(_ effect: @escaping @Sendable () throws -> T) async throws -> T {
  try await cancellableDiskIO { check in try check(); return try effect() }
}

func cancellableDiskIO<T: Sendable>(_ effect: @escaping @Sendable (@Sendable () throws -> Void) throws -> T) async throws -> T {
  let cancelled = Mutex(false)
  let check: @Sendable () throws -> Void = { if cancelled.withLock({ $0 }) { throw CancellationError() } }
  return try await withTaskCancellationHandler {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in
      diskQueue.async { continuation.resume(with: Result { try effect(check) }) }
    }
  } onCancel: { cancelled.withLock { $0 = true } }
}

func diskIO(_ effect: @escaping @Sendable () -> Void) async {
  await withCheckedContinuation { continuation in diskQueue.async { effect(); continuation.resume() } }
}

func closeDescriptor(_ fd: Int32) { _ = close(fd) }
func diskError() -> OperationError { .init(.fileUnavailable, details: ["errno": .integer(Int(errno))]) }
func fileStatus(_ path: String) throws -> ComputerFileStatus {
  var s = stat()
  guard lstat(path, &s) == 0 else { throw diskError() }
  return statusInfo(s)
}

func statusInfo(_ s: stat) -> ComputerFileStatus {
  let kind: String
  switch s.st_mode & mode_t(S_IFMT) {
  case mode_t(S_IFREG): kind = "file"
  case mode_t(S_IFDIR): kind = "directory"
  case mode_t(S_IFLNK): kind = "symlink"
  default: kind = "other"
  }
  #if os(Linux)
    let mt = s.st_mtim; let ct = s.st_ctim
  #else
    let mt = s.st_mtimespec; let ct = s.st_ctimespec
  #endif
  return .init(version: "\(s.st_dev):\(s.st_ino):\(s.st_size):\(mt.tv_sec):\(mt.tv_nsec):\(ct.tv_sec):\(ct.tv_nsec)", size: UInt64(max(0, s.st_size)), kind: kind)
}

#if os(Linux)
  private typealias DirectoryPointer = OpaquePointer
#else
  private typealias DirectoryPointer = UnsafeMutablePointer<DIR>
#endif

private enum DiskStep: Sendable { case entry(ComputerEntry), again, end }

private final class DiskWalk: Sendable {
  private struct Frame { let path: String; let directory: DirectoryPointer }
  private struct State { var pending: String?; var frames: [Frame] = []; var closed = false; var skipped: [String: Int] = [:] }
  private let state: Mutex<State>
  private let root: String
  private let symlinks: Bool
  private let beforeOpen: @Sendable (String) throws -> Void
  private let didInspect: @Sendable (String) -> Void
  init(root: String, symlinks: Bool, beforeOpen: @escaping @Sendable (String) throws -> Void, didInspect: @escaping @Sendable (String) -> Void) { state = Mutex(State(pending: root)); self.root = root; self.symlinks = symlinks; self.beforeOpen = beforeOpen; self.didInspect = didInspect }
  deinit { close() }
  func close() { state.withLock { state in for frame in state.frames { closedir(frame.directory) }; state.frames.removeAll(); state.closed = true } }
  func skipCounts() -> [String: Int] { state.withLock { $0.skipped } }
  private func openDirectory(_ path: String, status: ComputerFileStatus, parent: Int32?) throws -> Frame {
    try beforeOpen(path)
    let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    let fd = parent.map { openat($0, leaf(path), flags) } ?? open(path, flags)
    guard fd >= 0 else { throw diskError() }
    var value = stat()
    guard fstat(fd, &value) == 0, statusInfo(value) == status else { closeDescriptor(fd); throw OperationError(.fileChanged) }
    guard let dir = fdopendir(fd) else { let error = diskError(); closeDescriptor(fd); throw error }
    return Frame(path: path, directory: dir)
  }

  func step(check: @Sendable () throws -> Void) throws -> DiskStep {
    try state.withLock { state -> DiskStep in
      guard !state.closed else { return .end }
      while true {
        try check()
        if let path = state.pending {
          state.pending = nil
          do {
            guard path.utf8.count <= 4096 else { throw OperationError(.recordTooLarge) }
            let parent = path == root ? nil : state.frames.last.map { dirfd($0.directory) }
            let status = try parent.map { try statusAt($0, leaf(path)) } ?? fileStatus(path)
            if path == root && status.kind == "symlink" && !symlinks { throw OperationError(.invalidInput, message: "Search root is a symlink") }
            if status.kind == "directory" {
              guard state.frames.count < 128 else { throw OperationError.capacityExceeded("traversalDepth", used: state.frames.count, limit: 128) }
              state.frames.append(try openDirectory(path, status: status, parent: parent))
            } else if status.kind != "symlink" || symlinks {
              let file = status.kind == "file" ? try rootFile(path, status: status, beforeOpen: beforeOpen) : nil
              return .entry(.init(path: path, kind: status.kind, file: file))
            }
          } catch let error as OperationError where path != root && [.fileUnavailable, .fileChanged].contains(error.code) {
            state.skipped[error.code == .fileChanged ? "changed" : "unreadable", default: 0] += 1
            return .again
          }
        }
        guard let frame = state.frames.last else { state.closed = true; return .end }
        errno = 0
        guard let entry = readdir(frame.directory) else {
          if errno != 0 { state.skipped["unreadable", default: 0] += 1 }
          closedir(frame.directory); state.frames.removeLast(); return .again
        }
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
          pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
        }
        if name == "." || name == ".." { return .again }
        let path = (frame.path == "/" ? "" : frame.path) + "/" + name
        didInspect(path); try check()
        let child: ComputerFileStatus
        do { child = try statusAt(dirfd(frame.directory), name) }
        catch { state.skipped["unreadable", default: 0] += 1; return .again }
        if child.kind == "directory" { state.pending = path; return .entry(.init(path: path, kind: "directory")) }
        if child.kind == "symlink" && !symlinks { return .again }
        let file = child.kind == "file" ? try anchoredFile(dirfd(frame.directory), name: name, path: path, status: child, beforeOpen: beforeOpen) : nil
        return .entry(.init(path: path, kind: child.kind, file: file))
      }
    }
  }
}

private func leaf(_ path: String) -> String { String(path.split(separator: "/").last ?? "") }
private func statusAt(_ directory: Int32, _ name: String) throws -> ComputerFileStatus {
  var s = stat()
  guard fstatat(directory, name, &s, AT_SYMLINK_NOFOLLOW) == 0 else { throw diskError() }
  return statusInfo(s)
}

private final class DirectoryLease: Sendable {
  let fd: Int32
  init(_ original: Int32) throws {
    fd = fcntl(original, F_DUPFD_CLOEXEC, 0)
    guard fd >= 0 else { throw diskError() }
  }

  deinit { closeDescriptor(fd) }
}

private func rootFile(_ path: String, status: ComputerFileStatus, beforeOpen: @escaping @Sendable (String) throws -> Void) throws -> ComputerFile {
  let parent = String(path.prefix(upTo: path.lastIndex(of: "/")!))
  let fd = open(parent.isEmpty ? "/" : parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
  guard fd >= 0 else { throw diskError() }; defer { closeDescriptor(fd) }
  return try anchoredFile(fd, name: leaf(path), path: path, status: status, beforeOpen: beforeOpen)
}

private func anchoredFile(_ parent: Int32, name: String, path: String, status: ComputerFileStatus, beforeOpen: @escaping @Sendable (String) throws -> Void) throws -> ComputerFile {
  let directory = try DirectoryLease(parent)
  let verify: @Sendable () throws -> ComputerFileStatus = {
    guard try statusAt(directory.fd, name) == status else { throw OperationError(.fileChanged) }
    return status
  }
  return ComputerFile(status: { try await diskIO { try verify() } }, read: { offset, count in
    try await diskIO {
      guard count > 0 && count <= 65536, offset <= UInt64(Int64.max) else { throw OperationError(.invalidInput) }
      _ = try verify(); try beforeOpen(path)
      let fd = openat(directory.fd, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw diskError() }; defer { closeDescriptor(fd) }
      var value = stat()
      guard fstat(fd, &value) == 0, statusInfo(value) == status, status.kind == "file" else { throw OperationError(.fileChanged) }
      var bytes = Data(count: count)
      let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
      guard n >= 0 else { throw diskError() }
      guard fstat(fd, &value) == 0, statusInfo(value) == status else { throw OperationError(.fileChanged) }
      _ = try verify(); bytes.removeSubrange(n ..< bytes.count); return bytes
    }
  })
}
