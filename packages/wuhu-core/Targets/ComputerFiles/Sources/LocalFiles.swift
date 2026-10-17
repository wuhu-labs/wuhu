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
  /// `beforeOpen` runs on the disk queue before each read and each search effect, with its path; tests block or fail in it.
  static func local(beforeOpen: @escaping @Sendable (String) throws -> Void = { _ in }) -> Self {
    let effects = DiskEffects()
    return Self(status: { path in try await diskIO { try fileLookup { try fileStatus(path) } } }, read: { path, offset, count in
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
    }, search: { root in LocalSearchSource(root: root, effects: effects, beforeIO: beforeOpen) }, abandonedEffects: { effects.abandoned }, operations: .local)
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

/// Runs disk effects that their callers stop waiting for once cancelled: a
/// hung syscall cannot hold its caller. An abandoned effect runs to its end
/// anyway (`abandoned` tells it to stop early) and is counted in
/// ``abandoned`` until it does; a value it then returns goes to `discard`.
final class DiskEffects: Sendable {
  private let running = Mutex(0)

  /// Abandoned effects still queued or running.
  var abandoned: Int { running.withLock { $0 } }

  func run<T: Sendable>(discard: @escaping @Sendable (T) -> Void = { _ in }, _ effect: @escaping @Sendable (_ abandoned: @Sendable () -> Bool) throws -> T) async throws -> T {
    let phase = Mutex(EffectPhase<T>.starting)
    let isAbandoned: @Sendable () -> Bool = { phase.withLock { if case .abandoned = $0 { true } else { false } } }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let queued = phase.withLock { phase -> Bool in
          guard case .starting = phase else { return false }
          phase = .waiting(continuation)
          return true
        }
        guard queued else { continuation.resume(throwing: CancellationError()); return }
        diskQueue.async {
          guard !isAbandoned() else { self.running.withLock { $0 -= 1 }; return }
          let result = Result { try effect(isAbandoned) }
          let waiting = phase.withLock { phase -> CheckedContinuation<T, any Error>? in
            guard case let .waiting(continuation) = phase else { return nil }
            phase = .answered
            return continuation
          }
          if let waiting { waiting.resume(with: result); return }
          if case let .success(value) = result { discard(value) }
          self.running.withLock { $0 -= 1 }
        }
      }
    } onCancel: {
      let waiting = phase.withLock { phase -> CheckedContinuation<T, any Error>? in
        switch phase {
        case .starting: phase = .abandoned; return nil
        case let .waiting(continuation):
          phase = .abandoned
          self.running.withLock { $0 += 1 }
          return continuation
        case .answered, .abandoned: return nil
        }
      }
      waiting?.resume(throwing: CancellationError())
    }
  }
}

private enum EffectPhase<T: Sendable> {
  case starting
  case waiting(CheckedContinuation<T, any Error>)
  case answered
  case abandoned
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
