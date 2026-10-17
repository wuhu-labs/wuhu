#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import FileSearch
#if os(Linux)
  import Glibc
#else
  import Darwin
#endif
import Synchronization

/// The machine's disk as a search source. The root is followed if it is a
/// symlink; below it nothing is: every path is reached by `openat` from the
/// root, one `O_NOFOLLOW` component at a time, so a directory swapped for a
/// symlink mid-walk is unreadable rather than a way out. Paths outside the
/// root (the `.git` and `.gitignore` files of its ancestors) are opened as
/// they are. Every call is one of `effects`, abandoned, not awaited, once its
/// task is cancelled: a hung read cannot hold a search past its deadline or a
/// stop.
struct LocalSearchSource: SearchSource {
  let root: String
  let effects: DiskEffects
  /// Runs before each disk effect with the path it is for; tests block or fail in it.
  let beforeIO: @Sendable (String) throws -> Void

  init(root: String, effects: DiskEffects, beforeIO: @escaping @Sendable (String) throws -> Void = { _ in }) {
    var root = root
    while root.count > 1, root.hasSuffix("/") { root.removeLast() }
    self.root = root
    self.effects = effects
    self.beforeIO = beforeIO
  }

  func kind(_ path: String) async throws -> SearchEntryKind? {
    try await io(path) { _ in
      var value = stat()
      let failure: Int32
      do {
        failure = path == root
          ? (fstatat(AT_FDCWD, path, &value, 0) == 0 ? 0 : errno)
          : try at(path) { parent, name in fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 ? 0 : errno }
      } catch is Missing { return nil }
      if failure == ENOENT || failure == ENOTDIR { return nil }
      guard failure == 0 else { throw unreadable(failure) }
      return entryKind(value.st_mode)
    }
  }

  /// One pass over the directory keeps at most twice the page's names in
  /// memory, and only the page's children are stat'd.
  func children(of directory: String, from start: String, limit: Int) async throws -> SearchListing {
    try await io(directory) { abandoned in
      let fd = try openDirectory(directory)
      guard let handle = fdopendir(fd) else { let error = unreadable(); closeDescriptor(fd); throw error }
      defer { closedir(handle) }
      let keep = limit + 1
      var names: [String] = []
      func trim() { names.sort { $0.utf8.lexicographicallyPrecedes($1.utf8) }; names.removeLast(max(0, names.count - keep)) }
      while true {
        guard !abandoned() else { throw CancellationError() }
        errno = 0
        guard let entry = readdir(handle) else {
          if errno != 0 { throw unreadable() }
          break
        }
        let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
          pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
        }
        if name == "." || name == ".." || name.utf8.lexicographicallyPrecedes(start.utf8) { continue }
        names.append(name)
        if names.count >= 2 * keep { trim() }
      }
      trim()
      let next = names.count > limit ? names.removeLast() : nil
      var children: [SearchChild] = []
      for name in names {
        var value = stat()
        // A child that vanished since readdir is not listed; one that cannot be stat'd is listed as unreadable `other`.
        if fstatat(dirfd(handle), name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
          if errno == ENOENT { continue }
          children.append(.init(name: name, kind: .other))
        } else {
          children.append(.init(name: name, kind: entryKind(value.st_mode)))
        }
      }
      return SearchListing(children: children, next: next)
    }
  }

  func open(_ file: String) async throws -> any SearchReader {
    let fd = try await io(file, discard: { closeDescriptor($0) }) { _ in
      let flags = O_RDONLY | O_NONBLOCK | O_CLOEXEC
      let fd = file == root ? openPath(file, flags) : try at(file) { parent, name in openat(parent, name, flags | O_NOFOLLOW) }
      guard fd >= 0 else { throw unreadable() }
      var value = stat()
      guard fstat(fd, &value) == 0, value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { closeDescriptor(fd); throw SearchUnreadable("not a regular file") }
      return fd
    }
    return LocalSearchReader(fd: fd, path: file, effects: effects, beforeIO: beforeIO)
  }

  func isHidden(_ path: String) -> Bool { path.split(separator: "/").last?.hasPrefix(".") ?? false }

  private func io<T: Sendable>(_ path: String, discard: @escaping @Sendable (T) -> Void = { _ in }, _ effect: @escaping @Sendable (@Sendable () -> Bool) throws -> T) async throws -> T {
    try await effects.run(discard: discard) { abandoned in
      do { try beforeIO(path) } catch is CancellationError { throw CancellationError() } catch { throw SearchUnreadable("\(error)") }
      do { return try effect(abandoned) } catch is Missing { throw SearchUnreadable("no such file or directory") }
    }
  }

  /// Opens `directory`: the root following symlinks, anything else via ``at(_:_:)``.
  private func openDirectory(_ directory: String) throws -> Int32 {
    let flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC
    let fd = directory == root ? openPath(directory, flags) : try at(directory) { parent, name in openat(parent, name, flags | O_NOFOLLOW) }
    guard fd >= 0 else { throw unreadable() }
    return fd
  }

  /// Runs `body` with the directory holding `path` and its last name. Below
  /// the root the parent is reached from the root without following a link.
  private func at<T>(_ path: String, _ body: (Int32, String) throws -> T) throws -> T {
    let prefix = root == "/" ? "/" : root + "/"
    let inside = path.hasPrefix(prefix)
    var names = (inside ? path.dropFirst(prefix.count) : Substring(path)).split(separator: "/").map(String.init)
    guard let name = names.popLast() else { throw SearchUnreadable("no name") }
    var fd = openPath(inside ? root : "/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw unreadable() }
    defer { closeDescriptor(fd) }
    for component in names {
      let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | (inside ? O_NOFOLLOW : 0))
      guard next >= 0 else { throw errno == ENOENT || errno == ENOTDIR ? Missing() : unreadable() }
      closeDescriptor(fd)
      fd = next
    }
    return try body(fd, name)
  }
}

/// An open file, read with `pread`. Its descriptor is closed once the reader
/// is closed and no read, abandoned or not, still uses it.
final class LocalSearchReader: SearchReader {
  private struct State { var users = 0; var closed = false }
  private let fd: Int32
  private let path: String
  private let effects: DiskEffects
  private let beforeIO: @Sendable (String) throws -> Void
  private let state = Mutex(State())

  init(fd: Int32, path: String, effects: DiskEffects, beforeIO: @escaping @Sendable (String) throws -> Void) { self.fd = fd; self.path = path; self.effects = effects; self.beforeIO = beforeIO }
  deinit { if !state.withLock({ $0.closed }) { closeDescriptor(fd) } }

  /// The descriptor is taken for use inside the disk effect: a read abandoned
  /// before its effect ran never holds it.
  func read(at offset: Int, count: Int) async throws -> Data {
    try await effects.run { [fd, path, beforeIO] _ in
      guard self.state.withLock({ state -> Bool in if state.closed { return false }; state.users += 1; return true }) else { throw SearchUnreadable("closed") }
      defer { self.release() }
      do { try beforeIO(path) } catch is CancellationError { throw CancellationError() } catch { throw SearchUnreadable("\(error)") }
      var bytes = Data(count: count)
      let n = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
      guard n >= 0 else { throw unreadable() }
      bytes.removeSubrange(n ..< bytes.count)
      return bytes
    }
  }

  func close() async {
    let last = state.withLock { state -> Bool in
      guard !state.closed else { return false }
      state.closed = true
      return state.users == 0
    }
    if last { closeDescriptor(fd) }
  }

  private func release() {
    let last = state.withLock { state -> Bool in state.users -= 1; return state.closed && state.users == 0 }
    if last { closeDescriptor(fd) }
  }
}

private func entryKind(_ mode: mode_t) -> SearchEntryKind {
  switch mode & mode_t(S_IFMT) {
  case mode_t(S_IFDIR): .directory
  case mode_t(S_IFREG): .file
  default: .other
  }
}

private struct Missing: Error {}

private func unreadable(_ code: Int32 = errno) -> SearchUnreadable { SearchUnreadable(String(cString: strerror(code))) }

/// `open(2)`, out of reach of ``LocalSearchSource/open(_:)``'s name.
private func openPath(_ path: String, _ flags: Int32) -> Int32 { open(path, flags) }
