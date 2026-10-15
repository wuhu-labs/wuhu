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
@testable import SpaceServer
import Testing
import struct WorkerProtocol.WorkerProtocolError

private struct BootStorageFixture {
  let root: String
  let generation = UUID()
  var directory: String { root + "/" + generation.uuidString }
  let storage: ExecutionWorkerBootStorage
  var manifest: ExecutionWorkerManifest {
    .init(version: 1, space: "space", generation: generation, incarnation: UUID(), processID: getpid(), birth: "fixture-process-birth", credentials: .init(current: String(repeating: "a", count: 72)))
  }

  init() throws {
    let resolved = try #require(realpath("/tmp", nil))
    defer { free(resolved) }
    root = String(cString: resolved) + "/bf-" + String(UUID().uuidString.prefix(8))
    storage = .init(root: root, space: "space")
    #expect(mkdir(root, 0o700) == 0)
    #expect(mkdir(directory, 0o700) == 0)
  }

  func clean() { try? FileManager.default.removeItem(atPath: root) }
  func writeManifest(_ text: String) throws {
    let fd = open(directory + "/manifest.json", O_WRONLY | O_CREAT | O_EXCL, 0o600)
    #expect(fd >= 0)
    defer { _ = close(fd) }
    let data = Data(text.utf8)
    #expect(data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count)
  }
}

@Test func bootStorageMissingRootAndManifestDoNotCreateFiles() async throws {
  let fixture = try BootStorageFixture()
  defer { fixture.clean() }
  if case .missing = await fixture.storage.read(fixture.directory) {} else { Issue.record("Missing manifest was not classified") }
  #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory).isEmpty)
  let missing = ExecutionWorkerBootStorage(root: fixture.root + "/missing", space: "space")
  if case .missing = await missing.inventory() {} else { Issue.record("Missing root was not classified") }
  #expect(!FileManager.default.fileExists(atPath: fixture.root + "/missing"))
}

@Test(arguments: ["corrupt", "future", "foreign", "wrong-generation"])
func bootStorageClassifiesInvalidManifestWithoutRewriting(kind: String) async throws {
  let fixture = try BootStorageFixture()
  defer { fixture.clean() }
  let original = fixture.manifest
  let manifest = ExecutionWorkerManifest(version: 1, space: kind == "foreign" ? "another-space" : original.space, generation: kind == "wrong-generation" ? UUID() : original.generation, incarnation: original.incarnation, processID: original.processID, birth: original.birth, credentials: original.credentials)
  let text = kind == "future" ? "{\"version\":999,\"futureSchema\":true}" : kind == "corrupt" ? "bearer-must-not-leak" : String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
  try fixture.writeManifest(text)
  let result = await fixture.storage.read(fixture.directory)
  switch (kind, result) {
  case ("corrupt", .corrupt), ("future", .foreignVersion), ("foreign", .foreignSpace), ("wrong-generation", .corrupt): break
  default: Issue.record("Unexpected manifest classification")
  }
  #expect(try String(contentsOfFile: fixture.directory + "/manifest.json", encoding: .utf8) == text)
}

@Test func bootStorageFindsGenerationAndRemovesOnlyFencedKnownFiles() async throws {
  let fixture = try BootStorageFixture()
  defer { fixture.clean() }
  let store = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space")
  try await store.save(fixture.manifest)
  if case let .directories(values) = await fixture.storage.inventory() { #expect(values == [fixture.directory]) }
  else { Issue.record("Private worker inventory missing") }
  if case .manifest = await fixture.storage.read(fixture.directory) {} else { Issue.record("Valid generation refused") }
  try await fixture.storage.cleanup(fixture.directory)
  #expect(!FileManager.default.fileExists(atPath: fixture.directory))
  #expect(FileManager.default.fileExists(atPath: fixture.root))
}

@Test(arguments: ["unknown", "socket-symlink", "socket-regular"])
func bootStorageCleanupRefusesUnknownAndSubstitutedSocketFiles(kind: String) async throws {
  let fixture = try BootStorageFixture()
  defer { fixture.clean() }
  let store = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space")
  try await store.save(fixture.manifest)
  _ = await fixture.storage.read(fixture.directory)
  let name = kind == "unknown" ? "operator-file" : "worker.sock"
  let path = fixture.directory + "/" + name
  if kind == "socket-symlink" { #expect(symlink("/dev/null", path) == 0) }
  else {
    let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    #expect(fd >= 0)
    _ = close(fd)
  }
  await #expect(throws: WorkerProtocolError.self) { try await fixture.storage.cleanup(fixture.directory) }
  var state = stat()
  #expect(lstat(path, &state) == 0)
  if kind != "unknown" { #expect(FileManager.default.fileExists(atPath: fixture.directory + "/manifest.json")) }
}

@Test func bootStorageRefusesSymlinkedGenerationAndUnsafeRootWithoutRepair() async throws {
  let fixture = try BootStorageFixture()
  defer { fixture.clean() }
  let alias = fixture.root + "/" + UUID().uuidString
  #expect(symlink(fixture.directory, alias) == 0)
  if case .unsafeStorage = await fixture.storage.read(alias) {} else { Issue.record("Followed generation symlink") }
  #expect(chmod(fixture.root, 0o755) == 0)
  if case .unsafeStorage = await fixture.storage.inventory() {} else { Issue.record("Unsafe root accepted") }
  var state = stat()
  #expect(lstat(fixture.root, &state) == 0 && state.st_mode & 0o777 == 0o755)
}

@Test func bootStoragePinsTheReadDirectoryUntilFencedCleanup() async throws {
  let fixture = try BootStorageFixture()
  defer { fixture.clean() }
  let store = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space")
  let manifest = fixture.manifest
  try await store.save(manifest)
  _ = await fixture.storage.read(fixture.directory)
  let moved = fixture.directory + "-moved"
  #expect(rename(fixture.directory, moved) == 0)
  #expect(mkdir(fixture.directory, 0o700) == 0)
  let replacement = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space")
  try await replacement.save(manifest)
  await #expect(throws: WorkerProtocolError.self) { try await fixture.storage.cleanup(fixture.directory) }
  #expect(FileManager.default.fileExists(atPath: moved + "/manifest.json"))
  #expect(FileManager.default.fileExists(atPath: fixture.directory + "/manifest.json"))
}

@Test func bootFenceRecoversManifestWrittenBeforeTheWorkerWasSpawned() async throws {
  let fixture = try BootStorageFixture()
  defer { fixture.clean() }
  let original = fixture.manifest
  let manifest = ExecutionWorkerManifest(version: 1, space: original.space, generation: original.generation, incarnation: original.incarnation, processID: Int32.max, birth: original.birth, credentials: original.credentials)
  let store = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space")
  try await store.save(manifest)
  let result = await ExecutionWorkerBootFence.reconcile(effects: .init(inventory: { await fixture.storage.inventory() }, read: { await fixture.storage.read($0) }, process: { ExecutionWorkerBootProcess.inspect($0) }, terminate: { _, _ in
    Issue.record("No worker was spawned, so no authentication or signal is allowed")
    return .unconfirmed
  }, cleanup: { try await fixture.storage.cleanup($0) }, report: { _ in }))
  #expect(result.counts == [.absent: 1])
  #expect(result.unresolved.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: fixture.directory))
  #expect(!result.credentials.admits(manifest.credentials.current))
}

@Test(arguments: ["worker.sock", "parent.sock", "unknown-file"])
func bootStorageMissingManifestWithRuntimeEvidenceIsNotACleanStart(name: String) async throws {
  let fixture = try BootStorageFixture()
  defer { fixture.clean() }
  let fd = open(fixture.directory + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
  #expect(fd >= 0)
  _ = close(fd)
  if case .missingManifest = await fixture.storage.read(fixture.directory) {} else { Issue.record("Missing manifest hid runtime evidence") }
  #expect(FileManager.default.fileExists(atPath: fixture.directory + "/" + name))
}
