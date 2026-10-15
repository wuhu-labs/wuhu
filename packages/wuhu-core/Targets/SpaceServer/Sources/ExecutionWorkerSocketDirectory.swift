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
import struct WorkerProtocol.WorkerProtocolError

actor ExecutionWorkerSocketDirectory {
  private struct Identity: Codable, Equatable {
    let version: Int
    let space: String
    let generation: UUID
  }

  private struct FileIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    init(_ state: stat) { device = state.st_dev; inode = state.st_ino }
  }

  private let location: ExecutionWorkerSocketLocation
  private let identity: Identity
  private let descriptor: Int32
  private let rootIdentity: FileIdentity
  private let directoryIdentity: FileIdentity
  private let files: [String: FileIdentity]
  private static let names: Set<String> = ["identity.json", "worker.sock", "parent.sock"]

  private init(location: ExecutionWorkerSocketLocation, identity: Identity, descriptor: Int32, rootState: stat, state: stat, files: [String: FileIdentity]) {
    self.location = location; self.identity = identity; self.descriptor = descriptor
    rootIdentity = FileIdentity(rootState)
    directoryIdentity = FileIdentity(state); self.files = files
  }

  deinit { _ = close(descriptor) }

  static func create(space: String, generation: UUID, runtimeRoot: String = ExecutionWorkerSocketLocation.runtimeRoot) async throws -> ExecutionWorkerSocketLocation {
    let location = ExecutionWorkerSocketLocation(space: space, generation: generation, root: runtimeRoot)
    try location.validate(space: space, generation: generation, runtimeRoot: runtimeRoot)
    let bytes = try JSONEncoder().encode(Identity(version: 1, space: space, generation: generation))
    guard !space.isEmpty, bytes.count <= 8192 else { throw unsafeStorage() }
    let parent = String(runtimeRoot.prefix(upTo: runtimeRoot.lastIndex(of: "/")!))
    let name = String(runtimeRoot.suffix(from: runtimeRoot.index(after: runtimeRoot.lastIndex(of: "/")!)))
    let temporaryRoot = runtimeRoot == "/tmp/wuhu-" + String(geteuid()) || runtimeRoot == "/private/tmp/wuhu-" + String(geteuid())
    let parentFD = try ExecutionWorkerManifestStore.openDirectory(parent, requirePrivate: !temporaryRoot)
    defer { _ = close(parentFD) }
    if temporaryRoot {
      var state = stat()
      guard fstat(parentFD, &state) == 0,
            (state.st_uid == 0 && state.st_mode & S_ISVTX != 0)
            || ((state.st_uid == 0 || state.st_uid == geteuid()) && state.st_mode & 0o022 == 0)
      else { throw unsafeStorage() }
    }
    guard mkdirat(parentFD, name, 0o700) == 0 || errno == EEXIST else { throw unsafeStorage() }
    let root = try ExecutionWorkerManifestStore.openDirectory(runtimeRoot)
    defer { _ = close(root) }
    guard mkdirat(root, location.key, 0o700) == 0 else { throw unsafeStorage() }
    let directory = try ExecutionWorkerManifestStore.openDirectory(location.directory)
    defer { _ = close(directory) }
    let file = openat(directory, "identity.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw unsafeStorage() }
    defer { _ = close(file) }
    var offset = 0
    while offset < bytes.count {
      let count = bytes.withUnsafeBytes { write(file, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw unsafeStorage() }
      offset += count
    }
    guard fsync(file) == 0, fsync(directory) == 0, fsync(root) == 0 else { throw unsafeStorage() }
    // Read back through the same no-follow and full-identity gate used at boot.
    _ = try await openIfPresent(location, space: space, generation: generation, runtimeRoot: runtimeRoot)
    return location
  }

  static func openIfPresent(_ location: ExecutionWorkerSocketLocation, space: String, generation: UUID, runtimeRoot: String = ExecutionWorkerSocketLocation.runtimeRoot) async throws -> ExecutionWorkerSocketDirectory? {
    try location.validate(space: space, generation: generation, runtimeRoot: runtimeRoot)
    var state = stat()
    if lstat(location.root, &state) != 0, errno == ENOENT { return nil }
    let root = try ExecutionWorkerManifestStore.openDirectory(location.root)
    defer { _ = close(root) }
    var rootState = stat()
    guard fstat(root, &rootState) == 0 else { throw unsafeStorage() }
    if fstatat(root, location.key, &state, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT { return nil }
    let directory = try ExecutionWorkerManifestStore.openDirectory(location.directory)
    do {
      guard fstat(directory, &state) == 0 else { throw unsafeStorage() }
      let identity = Identity(version: 1, space: space, generation: generation)
      try ExecutionWorkerManifestStore.requireEntries(directory, allowed: names)
      let binding = try readIdentity(directory, expected: identity)
      var files = ["identity.json": binding]
      for name in ["worker.sock", "parent.sock"] {
        if let file = try socket(directory, name: name) { files[name] = file }
      }
      let currentRoot = try ExecutionWorkerManifestStore.openDirectory(location.root)
      defer { _ = close(currentRoot) }
      var currentRootState = stat()
      var childState = stat()
      guard fstat(currentRoot, &currentRootState) == 0, FileIdentity(currentRootState) == FileIdentity(rootState),
            fstatat(root, location.key, &childState, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity(childState) == FileIdentity(state)
      else { throw unsafeStorage() }
      return Self(location: location, identity: identity, descriptor: directory, rootState: rootState, state: state, files: files)
    } catch { _ = close(directory); throw error }
  }

  func removeEndpoints() throws {
    try verifyDirectory()
    try ExecutionWorkerManifestStore.requireEntries(descriptor, allowed: Self.names)
    guard try Self.readIdentity(descriptor, expected: identity) == files["identity.json"] else { throw Self.unsafeStorage() }
    for name in ["worker.sock", "parent.sock"] {
      let current = try Self.socket(descriptor, name: name)
      guard current == nil || current == files[name] else { throw Self.unsafeStorage() }
    }
    try verifyDirectory()
    for name in ["worker.sock", "parent.sock"] {
      guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else { throw Self.unsafeStorage() }
    }
    guard fsync(descriptor) == 0 else { throw Self.unsafeStorage() }
  }

  func cleanup() throws {
    try removeEndpoints()
    guard unlinkat(descriptor, "identity.json", 0) == 0, fsync(descriptor) == 0 else { throw Self.unsafeStorage() }
    try verifyDirectory()
    guard rmdir(location.directory) == 0 else { throw Self.unsafeStorage() }
  }

  private func verifyDirectory() throws {
    let root = try ExecutionWorkerManifestStore.openDirectory(location.root)
    defer { _ = close(root) }
    var rootState = stat()
    guard fstat(root, &rootState) == 0, FileIdentity(rootState) == rootIdentity else { throw Self.unsafeStorage() }
    let current = try ExecutionWorkerManifestStore.openDirectory(location.directory)
    defer { _ = close(current) }
    var state = stat()
    guard fstat(current, &state) == 0, FileIdentity(state) == directoryIdentity else { throw Self.unsafeStorage() }
  }

  private static func socket(_ directory: Int32, name: String) throws -> FileIdentity? {
    var state = stat()
    guard fstatat(directory, name, &state, AT_SYMLINK_NOFOLLOW) == 0 else {
      if errno == ENOENT { return nil }
      throw unsafeStorage()
    }
    guard state.st_uid == geteuid(), state.st_mode & S_IFMT == S_IFSOCK, state.st_mode & 0o7777 == 0o600 else { throw unsafeStorage() }
    return FileIdentity(state)
  }

  private static func readIdentity(_ directory: Int32, expected: Identity) throws -> FileIdentity {
    let file = openat(directory, "identity.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard file >= 0 else { throw unsafeStorage() }
    defer { _ = close(file) }
    var state = stat()
    guard fstat(file, &state) == 0, state.st_uid == geteuid(), state.st_mode & S_IFMT == S_IFREG,
          state.st_mode & 0o7777 == 0o600, state.st_nlink == 1, state.st_size > 0, state.st_size <= 8192
    else { throw unsafeStorage() }
    var bytes = [UInt8](repeating: 0, count: Int(state.st_size))
    var offset = 0
    while offset < bytes.count {
      let count = bytes.withUnsafeMutableBytes { read(file, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw unsafeStorage() }
      offset += count
    }
    var extra: UInt8 = 0
    guard read(file, &extra, 1) == 0, (try? JSONDecoder().decode(Identity.self, from: Data(bytes))) == expected else { throw unsafeStorage() }
    return FileIdentity(state)
  }

  private static func unsafeStorage() -> WorkerProtocolError {
    .init(.invalidConfiguration, message: "Execution worker socket storage must be owner-private and intact")
  }
}
