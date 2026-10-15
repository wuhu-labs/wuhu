#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Synchronization

private struct WriteDirectory: Hashable {
  let device: UInt64
  let inode: UInt64
}

private final class WriteLock: Sendable {
  let mutex = Mutex<Void>(())
}

private struct WriteLockEntry {
  let lock: WriteLock
  var users: Int
}

private let localWriteLocks = Mutex<[WriteDirectory: WriteLockEntry]>([:])

func withLocalWriteLock<T>(parent: Int32, body: () throws -> T) throws -> T {
  var status = stat()
  guard fstat(parent, &status) == 0 else { throw diskError() }
  let target = WriteDirectory(device: UInt64(truncatingIfNeeded: status.st_dev), inode: UInt64(truncatingIfNeeded: status.st_ino))
  let lock = localWriteLocks.withLock { entries in
    var entry = entries[target] ?? WriteLockEntry(lock: WriteLock(), users: 0)
    entry.users += 1
    entries[target] = entry
    return entry.lock
  }
  defer {
    localWriteLocks.withLock { entries in
      entries[target]!.users -= 1
      if entries[target]!.users == 0 { entries.removeValue(forKey: target) }
    }
  }
  return try lock.mutex.withLock { _ in try body() }
}
