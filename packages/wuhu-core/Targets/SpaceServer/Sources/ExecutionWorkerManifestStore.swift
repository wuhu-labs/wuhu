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
import ImageRetention
import struct WorkerProtocol.WorkerProtocolError

actor ExecutionWorkerManifestStore {
  private let directory: String
  private let runtimeRoot: String
  private let space: String
  private let descriptor: Int32
  private let device: dev_t
  private let inode: ino_t
  private static let maximumBytes = 8192

  private init(directory: String, space: String, runtimeRoot: String, descriptor: Int32, state: stat) {
    self.directory = directory; self.space = space; self.descriptor = descriptor
    self.runtimeRoot = runtimeRoot
    device = state.st_dev; inode = state.st_ino
  }

  deinit { _ = close(descriptor) }

  static func open(directory: String, space: String, runtimeRoot: String = ExecutionWorkerSocketLocation.runtimeRoot) async throws -> ExecutionWorkerManifestStore {
    let descriptor = try openDirectory(directory)
    var state = stat()
    guard fstat(descriptor, &state) == 0 else { _ = close(descriptor); throw unsafeStorage() }
    return Self(directory: directory, space: space, runtimeRoot: runtimeRoot, descriptor: descriptor, state: state)
  }

  static func create(root: String, generation: UUID, space: String, runtimeRoot: String = ExecutionWorkerSocketLocation.runtimeRoot) async throws -> ExecutionWorkerManifestStore {
    let parent = try openDirectory(root)
    defer { _ = close(parent) }
    let name = generation.uuidString
    guard mkdirat(parent, name, 0o700) == 0 else { throw unsafeStorage() }
    let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw unsafeStorage() }
    var state = stat()
    guard fstat(descriptor, &state) == 0, state.st_uid == geteuid(), state.st_mode & 0o7777 == 0o700, fsync(parent) == 0 else {
      _ = close(descriptor)
      throw unsafeStorage()
    }
    let store = Self(directory: root + "/" + name, space: space, runtimeRoot: runtimeRoot, descriptor: descriptor, state: state)
    try await store.verifyDirectory()
    return store
  }

  func load() async throws -> ExecutionWorkerManifest? {
    guard let data = try readRecord("manifest.json") else { return nil }
    let manifest: ExecutionWorkerManifest
    do { manifest = try JSONDecoder().decode(ExecutionWorkerManifest.self, from: data) }
    catch { throw Self.unsafeStorage() }
    try manifest.validate(directory: directory, space: space, runtimeRoot: runtimeRoot)
    return manifest
  }

  func inspectForBoot() -> ExecutionWorkerBootFence.Read {
    let data: Data
    do {
      guard let bytes = try readRecord("manifest.json") else { return .missing }
      data = bytes
    } catch { return .unsafeStorage }
    struct Header: Decodable { let version: Int }
    do {
      guard [1, 2].contains(try JSONDecoder().decode(Header.self, from: data).version) else { return .foreignVersion }
    } catch { return .corrupt }
    let manifest: ExecutionWorkerManifest
    do { manifest = try JSONDecoder().decode(ExecutionWorkerManifest.self, from: data) }
    catch { return .corrupt }
    guard manifest.space == space else { return .foreignSpace }
    do { try manifest.validate(directory: directory, space: space, runtimeRoot: runtimeRoot) }
    catch { return .corrupt }
    return .manifest(manifest)
  }

  func hasRuntimeFiles() throws -> Bool {
    try verifyDirectory()
    let directory = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard directory >= 0 else { throw Self.unsafeStorage() }
    guard let entries = fdopendir(directory) else { _ = close(directory); throw Self.unsafeStorage() }
    defer { _ = closedir(entries) }
    errno = 0
    while let entry = readdir(entries) {
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
      }
      if name != ".", name != ".." { return true }
      errno = 0
    }
    guard errno == 0 else { throw Self.unsafeStorage() }
    return false
  }

  private func readRecord(_ name: String) throws -> Data? {
    try verifyDirectory()
    let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard file >= 0 else {
      if errno == ENOENT { return nil }
      throw Self.unsafeStorage()
    }
    defer { _ = close(file) }
    let state = try Self.validateFile(file)
    var bytes = [UInt8](repeating: 0, count: Int(state.st_size))
    var offset = 0
    while offset < bytes.count {
      let count = bytes.withUnsafeMutableBytes { read(file, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw Self.unsafeStorage() }
      offset += count
    }
    var extra: UInt8 = 0
    guard read(file, &extra, 1) == 0 else { throw Self.unsafeStorage() }
    return Data(bytes)
  }

  func save(_ manifest: ExecutionWorkerManifest) async throws {
    try manifest.validate(directory: directory, space: space, runtimeRoot: runtimeRoot)
    guard try readRecord("cleanup.json") == nil else { throw Self.unsafeStorage() }
    if manifest.sockets != nil { try Self.requireEntries(descriptor, allowed: ["manifest.json", "preparation.json"]) }
    try saveRecord(JSONEncoder().encode(manifest), name: "manifest.json")
  }

  private func saveRecord(_ bytes: Data, name: String) throws {
    try verifyDirectory()
    try validateExistingFile(name: name)
    guard bytes.count <= Self.maximumBytes else { throw Self.unsafeStorage() }
    let temporary = ".manifest-" + UUID().uuidString
    let file = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
    guard file >= 0 else { throw Self.unsafeStorage() }
    defer { _ = close(file); _ = unlinkat(descriptor, temporary, 0) }
    var offset = 0
    while offset < bytes.count {
      let count = bytes.withUnsafeBytes { write(file, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { throw Self.unsafeStorage() }
      offset += count
    }
    _ = try Self.validateFile(file)
    guard fsync(file) == 0 else { throw Self.unsafeStorage() }
    try verifyDirectory()
    try validateExistingFile(name: name)
    guard renameat(descriptor, temporary, descriptor, name) == 0, fsync(descriptor) == 0 else { throw Self.unsafeStorage() }
  }

  func loadPreparation() throws -> ExecutionWorkerPreparation? {
    guard let bytes = try readRecord("preparation.json") else { return nil }
    guard let record = try? JSONDecoder().decode(ExecutionWorkerPreparation.self, from: bytes),
          let generation = UUID(uuidString: URL(fileURLWithPath: directory).lastPathComponent) else { throw Self.unsafeStorage() }
    try record.validate(space: space, generation: generation, runtimeRoot: runtimeRoot)
    return record
  }

  func savePreparation(_ record: ExecutionWorkerPreparation) throws {
    try record.validate(space: space, generation: record.generation, runtimeRoot: runtimeRoot)
    try Self.requireEntries(descriptor, allowed: [])
    try saveRecord(JSONEncoder().encode(record), name: "preparation.json")
  }

  func removePreparation() throws {
    guard unlinkat(descriptor, "preparation.json", 0) == 0 || errno == ENOENT, fsync(descriptor) == 0 else { throw Self.unsafeStorage() }
  }

  func preparationImage(_ reference: ImageReference) throws -> ImageReference? {
    let config = URL(fileURLWithPath: directory).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try ImageRetention.transaction(root: config.appendingPathComponent("execution-images").path) { store in
      let current = try store.references().first { $0.id == reference.id }
      guard current == nil || current?.digest == reference.digest && current?.owner == reference.owner else { throw Self.unsafeStorage() }
      return current
    }
  }

  func loadCleanup() throws -> ExecutionWorkerCleanup? {
    guard let bytes = try readRecord("cleanup.json") else { return nil }
    guard let record = try? JSONDecoder().decode(ExecutionWorkerCleanup.self, from: bytes) else { throw Self.unsafeStorage() }
    return record
  }

  func stageCleanup(_ record: ExecutionWorkerCleanup, manifest: ExecutionWorkerManifest?) async throws {
    guard try await load() == manifest, try loadCleanup() == nil else { throw Self.unsafeStorage() }
    try validateFencedRuntime(socketsInDirectory: false)
    try saveRecord(JSONEncoder().encode(record), name: "cleanup.json")
  }

  func retireCleanupManifest(_ record: ExecutionWorkerCleanup) async throws {
    guard try loadCleanup() == record else { throw Self.unsafeStorage() }
    try Self.requireEntries(descriptor, allowed: ["manifest.json", "cleanup.json", "preparation.json"])
    if let manifest = try await load() {
      guard manifest.space == record.space, manifest.generation == record.generation, manifest.sockets == record.location else { throw Self.unsafeStorage() }
    }
    try await remove()
    try removePreparation()
  }

  func releaseImage(_ reference: ImageReference) throws {
    let config = URL(fileURLWithPath: directory).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    try ImageRetention.transaction(root: config.appendingPathComponent("execution-images").path) { try $0.release(reference) }
  }

  func removeCleanup(_ record: ExecutionWorkerCleanup) throws {
    guard try loadCleanup() == record else { throw Self.unsafeStorage() }
    try Self.requireEntries(descriptor, allowed: ["cleanup.json"])
    guard unlinkat(descriptor, "cleanup.json", 0) == 0, fsync(descriptor) == 0 else { throw Self.unsafeStorage() }
    try verifyDirectory()
    guard rmdir(directory) == 0 else { throw Self.unsafeStorage() }
  }

  func remove() async throws {
    try verifyDirectory()
    try validateExistingFile()
    guard unlinkat(descriptor, "manifest.json", 0) == 0 || errno == ENOENT else { throw Self.unsafeStorage() }
    guard fsync(descriptor) == 0 else { throw Self.unsafeStorage() }
  }

  func removeFencedRuntime(socketsInDirectory: Bool = true) async throws {
    try validateFencedRuntime(socketsInDirectory: socketsInDirectory)
    let names = (socketsInDirectory ? ["worker.sock", "parent.sock"] : []) + ["manifest.json"]
    try verifyDirectory()
    for name in names {
      guard unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else { throw Self.unsafeStorage() }
    }
    guard fsync(descriptor) == 0 else { throw Self.unsafeStorage() }
    try verifyDirectory()
    guard rmdir(directory) == 0 else { throw Self.unsafeStorage() }
  }

  func validateFencedRuntime(socketsInDirectory: Bool) throws {
    try verifyDirectory()
    try validateExistingFile()
    let socketNames = socketsInDirectory ? ["worker.sock", "parent.sock"] : []
    try Self.requireEntries(descriptor, allowed: Set(socketNames + ["manifest.json", "preparation.json"]))
    for name in socketNames {
      var state = stat()
      if fstatat(descriptor, name, &state, AT_SYMLINK_NOFOLLOW) == 0 {
        guard state.st_uid == geteuid(), state.st_mode & S_IFMT == S_IFSOCK else { throw Self.unsafeStorage() }
      } else if errno != ENOENT { throw Self.unsafeStorage() }
    }
  }

  private func verifyDirectory() throws {
    let current = try Self.openDirectory(directory)
    defer { _ = close(current) }
    var state = stat()
    guard fstat(current, &state) == 0, state.st_dev == device, state.st_ino == inode else { throw Self.unsafeStorage() }
  }

  private func validateExistingFile(name: String = "manifest.json") throws {
    let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard file >= 0 else {
      if errno == ENOENT { return }
      throw Self.unsafeStorage()
    }
    defer { _ = close(file) }
    _ = try Self.validateFile(file)
  }

  private static func validateFile(_ descriptor: Int32) throws -> stat {
    var state = stat()
    guard fstat(descriptor, &state) == 0, state.st_uid == geteuid(), state.st_mode & 0o7777 == 0o600,
          state.st_mode & S_IFMT == S_IFREG, state.st_nlink == 1, state.st_size > 0, state.st_size <= maximumBytes
    else { throw unsafeStorage() }
    return state
  }

  static func openDirectory(_ path: String, requirePrivate: Bool = true) throws -> Int32 {
    guard path.hasPrefix("/"), !path.utf8.contains(0), !path.hasSuffix("/") else { throw unsafeStorage() }
    let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw unsafeStorage() }
    #if os(Linux)
      var descriptor = Glibc.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    #else
      var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    #endif
    guard descriptor >= 0 else { throw unsafeStorage() }
    for component in components {
      let child = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
      _ = close(descriptor)
      guard child >= 0 else { throw unsafeStorage() }
      descriptor = child
    }
    var state = stat()
    guard fstat(descriptor, &state) == 0, state.st_mode & S_IFMT == S_IFDIR,
          !requirePrivate || (state.st_uid == geteuid() && state.st_mode & 0o7777 == 0o700)
    else {
      _ = close(descriptor)
      throw unsafeStorage()
    }
    return descriptor
  }

  static func requireEntries(_ descriptor: Int32, allowed: Set<String>) throws {
    let copy = openat(descriptor, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard copy >= 0 else { throw unsafeStorage() }
    guard let entries = fdopendir(copy) else { _ = close(copy); throw unsafeStorage() }
    defer { _ = closedir(entries) }
    errno = 0
    while let entry = readdir(entries) {
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
      }
      guard name == "." || name == ".." || allowed.contains(name) else { throw unsafeStorage() }
      errno = 0
    }
    guard errno == 0 else { throw unsafeStorage() }
  }

  private static func unsafeStorage() -> WorkerProtocolError {
    .init(.invalidConfiguration, message: "Execution worker manifest storage must be owner-private and intact")
  }
}
