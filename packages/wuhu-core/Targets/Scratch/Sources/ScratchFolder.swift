#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#endif

/// A fresh folder under this process's scratch root, `$TMPDIR/wuhu-scratch-<pid>/<label>-<uuid>`.
///
/// It is removed by ``remove()`` or when released, and at the latest when the process exits: the whole root goes
/// at exit, and the first folder a process makes removes the roots of processes that are gone.
public final class ScratchFolder: Sendable {
  public let url: URL

  public init(_ label: String) throws {
    url = try scratchURL(label)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  public var path: String { url.path }

  public func remove() {
    try? FileManager.default.removeItem(at: url)
  }

  deinit { remove() }
}

/// A fresh path under this process's scratch root, `<label>-<uuid>`, not yet created. The caller removes what it
/// makes there; process exit is the backstop.
public func scratchURL(_ label: String) throws -> URL {
  try ScratchRoot.url.get().appending(path: "\(label)-\(UUID().uuidString)")
}

enum ScratchRoot {
  static let prefix = "wuhu-scratch-"
  static let url: Result<URL, any Error> = Result { try make() }

  static func make() throws -> URL {
    let base = baseDirectory()
    sweep(base)
    let root = base.appending(path: "\(prefix)\(getpid())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    atexit { ScratchRoot.removeAtExit() }
    return root
  }

  // Darwin's Foundation ignores TMPDIR; honouring it keeps a child process's scratch where its parent put it.
  static func baseDirectory() -> URL {
    if let tmp = ProcessInfo.processInfo.environment["TMPDIR"], !tmp.isEmpty {
      return URL(filePath: tmp, directoryHint: .isDirectory)
    }
    return FileManager.default.temporaryDirectory
  }

  static func sweep(_ base: URL) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: base.path) else { return }
    for name in names where name.hasPrefix(prefix) {
      guard let pid = pid_t(name.dropFirst(prefix.count)), pid != getpid(), !isAlive(pid) else { continue }
      try? FileManager.default.removeItem(at: base.appending(path: name, directoryHint: .isDirectory))
    }
  }

  static func isAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno != ESRCH
  }

  static func removeAtExit() {
    guard case let .success(root) = url else { return }
    try? FileManager.default.removeItem(at: root)
  }
}
