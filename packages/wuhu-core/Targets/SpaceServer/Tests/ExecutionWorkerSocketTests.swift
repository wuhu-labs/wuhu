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
import Fetch
@testable import SpaceServer
import Testing
import WorkerProtocol

private struct SocketFixture {
  let base: String
  let space = UUID().uuidString.lowercased()
  let generation = UUID()
  var root: String { base + "/r" }
  var location: ExecutionWorkerSocketLocation { .init(space: space, generation: generation, root: root) }
  var directory: String { base + "/deliberately-long-canonical-config-path/workers/" + space + "/" + generation.uuidString }
  var manifest: ExecutionWorkerManifest {
    .init(version: 2, space: space, generation: generation, incarnation: UUID(), processID: Int32.max, birth: "fixture-process-birth", credentials: .init(current: String(repeating: "a", count: 72)), sockets: location)
  }

  init() throws {
    let resolved = try #require(realpath("/tmp", nil))
    defer { free(resolved) }
    base = String(cString: resolved) + "/ws-" + String(UUID().uuidString.prefix(8))
    #expect(mkdir(base, 0o700) == 0)
  }

  func clean() { try? FileManager.default.removeItem(atPath: base) }
  func create() async throws { #expect(try await ExecutionWorkerSocketDirectory.create(space: space, generation: generation, runtimeRoot: root) == location) }
  func pin() async throws -> ExecutionWorkerSocketDirectory {
    try #require(await ExecutionWorkerSocketDirectory.openIfPresent(location, space: space, generation: generation, runtimeRoot: root))
  }

  func bootStorage() async throws -> ExecutionWorkerBootStorage {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let store = try await ExecutionWorkerManifestStore.open(directory: directory, space: space, runtimeRoot: root)
    try await store.save(manifest)
    return .init(root: String(directory.prefix(upTo: directory.lastIndex(of: "/")!)), space: space, runtimeRoot: root)
  }
}

@Test func workerSocketRootSelectionAndIdentityAreBoundedAndDeterministic() throws {
  let generation = UUID()
  let first = ExecutionWorkerSocketLocation(space: "ab:c", generation: generation)
  #expect(first == ExecutionWorkerSocketLocation(space: "ab:c", generation: generation))
  #expect(first != ExecutionWorkerSocketLocation(space: "a:bc", generation: generation))
  #expect(first != ExecutionWorkerSocketLocation(space: "ab:c", generation: UUID()))
  #expect(first.worker.utf8.count < 104 && first.parent.utf8.count < 104)
  let root = ExecutionWorkerSocketLocation.selectRoot(environment: [:])
  #expect(ExecutionWorkerSocketLocation.selectRoot(environment: ["XDG_RUNTIME_DIR": "/" + String(repeating: "x", count: 120)]) == root)
  #expect(ExecutionWorkerSocketLocation.selectRoot(environment: ["XDG_RUNTIME_DIR": "relative"]) == root)
  #expect(ExecutionWorkerSocketLocation.selectRoot(environment: ["XDG_RUNTIME_DIR": "/tmp/../unsafe"]) == root)
  #if os(Linux)
    var state = stat()
    state.st_mode = mode_t(S_IFDIR | 0o700); state.st_uid = geteuid()
    #expect(ExecutionWorkerSocketLocation.selectRoot(environment: ["XDG_RUNTIME_DIR": "/run/user/123"], parentState: { _ in state }) == "/run/user/123/wuhu")
  #else
    #expect(ExecutionWorkerSocketLocation.selectRoot(environment: ["XDG_RUNTIME_DIR": "/run/user/123"]) == root)
  #endif
  let tooLong = ExecutionWorkerSocketLocation(space: "space", generation: generation, root: "/" + String(repeating: "é", count: 50))
  #expect(throws: WorkerProtocolError.self) { try tooLong.validate(space: "space", generation: generation, runtimeRoot: tooLong.root) }
}

@Test func workerSocketsBindAtShortAddressesWhileCanonicalManifestsStayLong() async throws {
  let fixture = try SocketFixture()
  defer { fixture.clean() }
  try await fixture.create()
  #expect((fixture.directory + "/worker.sock").utf8.count >= 104)
  let worker = try await WorkerListener.bind(socket: fixture.location.worker, handler: { _ in .text("worker") })
  let parent = try await WorkerListener.bind(socket: fixture.location.parent, handler: { _ in .text("parent") })
  let storage = try await fixture.bootStorage()
  let manifest = fixture.manifest
  #expect(manifest.workerSocket(directory: fixture.directory) == fixture.location.worker)
  if case let .manifest(loaded) = await storage.read(fixture.directory) { #expect(loaded.sockets == fixture.location) }
  else { Issue.record("Long canonical manifest did not load") }
  await worker.shutdown()
  await parent.shutdown()
  try await storage.cleanup(fixture.directory)
  #expect(!FileManager.default.fileExists(atPath: fixture.directory))
  #expect(!FileManager.default.fileExists(atPath: fixture.location.directory))
  #expect(FileManager.default.fileExists(atPath: fixture.root))
}

@Test func workerSocketAllocationNeverReusesAnExistingGeneration() async throws {
  let fixture = try SocketFixture()
  defer { fixture.clean() }
  try await fixture.create()
  let binding = try Data(contentsOf: URL(fileURLWithPath: fixture.location.directory + "/identity.json"))
  await #expect(throws: WorkerProtocolError.self) { try await fixture.create() }
  #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.location.directory + "/identity.json")) == binding)
}

@Test(arguments: ["root-mode", "root-symlink", "directory-mode", "directory-symlink", "binding-mode", "binding-symlink", "binding-hardlink", "binding-fifo", "binding-oversize", "binding-missing", "binding-identity", "socket-regular", "socket-symlink", "unknown"])
func workerSocketStorageRefusesUnsafeRootsEntriesAndIdentityCollisions(kind: String) async throws {
  let fixture = try SocketFixture()
  defer { fixture.clean() }
  try await fixture.create()
  let binding = fixture.location.directory + "/identity.json"
  switch kind {
  case "root-mode": #expect(chmod(fixture.root, 0o755) == 0)
  case "root-symlink":
    #expect(rename(fixture.root, fixture.root + "-moved") == 0)
    #expect(symlink(fixture.root + "-moved", fixture.root) == 0)
  case "directory-mode": #expect(chmod(fixture.location.directory, 0o755) == 0)
  case "directory-symlink":
    #expect(rename(fixture.location.directory, fixture.location.directory + "-moved") == 0)
    #expect(symlink(fixture.location.directory + "-moved", fixture.location.directory) == 0)
  case "binding-mode": #expect(chmod(binding, 0o644) == 0)
  case "binding-hardlink": #expect(link(binding, fixture.base + "/binding-link") == 0)
  case "binding-identity":
    let other = "{\"version\":1,\"space\":\"another-space\",\"generation\":\"" + fixture.generation.uuidString + "\"}"
    try Data(other.utf8).write(to: URL(fileURLWithPath: binding))
  case "socket-regular", "unknown":
    let path = kind == "unknown" ? fixture.location.directory + "/operator-file" : fixture.location.worker
    #expect(FileManager.default.createFile(atPath: path, contents: Data()))
  case "socket-symlink": #expect(symlink("/dev/null", fixture.location.worker) == 0)
  default:
    #expect(unlink(binding) == 0)
    if kind == "binding-symlink" { #expect(symlink("/dev/null", binding) == 0) }
    if kind == "binding-fifo" { #expect(mkfifo(binding, 0o600) == 0) }
    if kind == "binding-oversize" { #expect(FileManager.default.createFile(atPath: binding, contents: Data(repeating: 1, count: 8193), attributes: [.posixPermissions: 0o600])) }
  }
  await #expect(throws: WorkerProtocolError.self) { try await fixture.pin() }
  let storage = try await fixture.bootStorage()
  if case .unsafeStorage = await storage.read(fixture.directory) {} else { Issue.record("Unsafe socket storage bypassed boot gate") }
  #expect(FileManager.default.fileExists(atPath: fixture.directory + "/manifest.json"))
  if kind == "root-mode" {
    await #expect(throws: WorkerProtocolError.self) { try await ExecutionWorkerSocketDirectory.create(space: fixture.space, generation: UUID(), runtimeRoot: fixture.root) }
    var state = stat()
    #expect(lstat(fixture.root, &state) == 0 && state.st_mode & 0o777 == 0o755)
  }
}

@Test(arguments: ["directory", "root", "root-with-original-directory", "binding", "socket", "unknown", "canonical-unknown"])
func workerSocketCleanupPinsBothDirectoriesBindingAndSocketInodes(kind: String) async throws {
  let fixture = try SocketFixture()
  defer { fixture.clean() }
  try await fixture.create()
  let listener = try await WorkerListener.bind(socket: fixture.location.worker, handler: { _ in .text("fixture") })
  let storage = try await fixture.bootStorage()
  if case .manifest = await storage.read(fixture.directory) {} else { Issue.record("Could not pin manifest") }
  let binding = fixture.location.directory + "/identity.json"
  var replacement: WorkerListener?
  switch kind {
  case "directory", "root":
    let path = kind == "root" ? fixture.root : fixture.location.directory
    #expect(rename(path, path + "-moved") == 0)
    try await fixture.create()
  case "root-with-original-directory":
    #expect(rename(fixture.root, fixture.root + "-moved") == 0)
    #expect(mkdir(fixture.root, 0o700) == 0)
    #expect(rename(fixture.root + "-moved/" + fixture.location.key, fixture.location.directory) == 0)
  case "binding":
    let bytes = try Data(contentsOf: URL(fileURLWithPath: binding))
    #expect(rename(binding, fixture.base + "/old-binding") == 0)
    #expect(FileManager.default.createFile(atPath: binding, contents: bytes, attributes: [.posixPermissions: 0o600]))
  case "socket":
    #expect(rename(fixture.location.worker, fixture.base + "/old-worker.sock") == 0)
    replacement = try await WorkerListener.bind(socket: fixture.location.worker, handler: { _ in .text("replacement") })
  default:
    let path = kind == "unknown" ? fixture.location.directory : fixture.directory
    #expect(FileManager.default.createFile(atPath: path + "/operator-file", contents: Data()))
  }
  await #expect(throws: WorkerProtocolError.self) { try await storage.cleanup(fixture.directory) }
  #expect(FileManager.default.fileExists(atPath: fixture.directory + "/manifest.json"))
  #expect(FileManager.default.fileExists(atPath: binding))
  await listener.shutdown()
  await replacement?.shutdown()
}

@Test(arguments: [false, true])
func workerSocketMissingDirectoryAllowsDeadProcessCleanupButNeverIgnoresNewEvidence(appears: Bool) async throws {
  let fixture = try SocketFixture()
  defer { fixture.clean() }
  let storage = try await fixture.bootStorage()
  if case .manifest = await storage.read(fixture.directory) {} else { Issue.record("Missing runtime directory must not block process inspection") }
  if appears {
    try await fixture.create()
    await #expect(throws: WorkerProtocolError.self) { try await storage.cleanup(fixture.directory) }
    #expect(FileManager.default.fileExists(atPath: fixture.directory + "/manifest.json"))
  } else {
    try await storage.cleanup(fixture.directory)
    #expect(!FileManager.default.fileExists(atPath: fixture.directory))
    #expect(FileManager.default.fileExists(atPath: fixture.root))
  }
}

@Test(arguments: ["foreign-root", "wrong-key", "legacy-with-sockets", "v2-without-sockets"])
func workerManifestRejectsUnboundSocketLayouts(kind: String) async throws {
  let fixture = try SocketFixture()
  defer { fixture.clean() }
  let original = fixture.manifest
  let sockets: ExecutionWorkerSocketLocation?
  if kind == "v2-without-sockets" { sockets = nil }
  else if kind == "foreign-root" { sockets = .init(space: fixture.space, generation: fixture.generation, root: fixture.base + "/foreign") }
  else if kind == "wrong-key" { sockets = .init(space: "other-space", generation: fixture.generation, root: fixture.root) }
  else { sockets = original.sockets }
  let manifest = ExecutionWorkerManifest(version: kind == "legacy-with-sockets" ? 1 : 2, space: original.space, generation: original.generation, incarnation: original.incarnation, processID: original.processID, birth: original.birth, credentials: original.credentials, sockets: sockets)
  #expect(throws: WorkerProtocolError.self) { try manifest.validate(directory: fixture.directory, space: fixture.space, runtimeRoot: fixture.root) }
}

@Test(arguments: ["missing", "not-directory", "foreign-owner", "mode"])
func workerSocketUnusableXDGParentFallsBack(kind: String) {
  var state = stat()
  state.st_mode = mode_t(S_IFDIR | 0o700); state.st_uid = geteuid()
  if kind == "not-directory" { state.st_mode = mode_t(S_IFREG | 0o700) }
  if kind == "foreign-owner" { state.st_uid = geteuid() == 0 ? 1 : 0 }
  if kind == "mode" { state.st_mode = mode_t(S_IFDIR | 0o755) }
  let root = ExecutionWorkerSocketLocation.selectRoot(environment: ["XDG_RUNTIME_DIR": "/run/user/123"], parentState: { _ in kind == "missing" ? nil : state })
  #expect(root == ExecutionWorkerSocketLocation.selectRoot(environment: [:]))
}

@Test func workerSocketUnsafeXDGChildRootIsRefusedWithoutFallback() async throws {
  #if os(Linux)
    let fixture = try SocketFixture()
    defer { fixture.clean() }
    let environment = ["XDG_RUNTIME_DIR": fixture.base]
    let root = ExecutionWorkerSocketLocation.selectRoot(environment: environment)
    #expect(root == fixture.base + "/wuhu")
    #expect(mkdir(root, 0o755) == 0)
    #expect(ExecutionWorkerSocketLocation.selectRoot(environment: environment) == root)
    await #expect(throws: WorkerProtocolError.self) { try await ExecutionWorkerSocketDirectory.create(space: fixture.space, generation: fixture.generation, runtimeRoot: root) }
    var state = stat()
    #expect(lstat(root, &state) == 0 && state.st_mode & 0o777 == 0o755)
  #endif
}

@Test(arguments: [false, true])
func workerSocketCleanupClaimBlocksAllocationUntilCanonicalDeletion(runtimePresent: Bool) async throws {
  let fixture = try SocketFixture()
  defer { fixture.clean() }
  let storage = try await fixture.bootStorage()
  if runtimePresent { try await fixture.create() }
  if case .manifest = await storage.read(fixture.directory) {} else { Issue.record("Could not inspect fixture") }
  // Missing runtime cleanup uses the same exclusive allocator, never an absence recheck.
  if !runtimePresent { try await fixture.create() }
  let claim = try await fixture.pin()
  try await claim.removeEndpoints()
  #expect(FileManager.default.fileExists(atPath: fixture.location.directory + "/identity.json"))
  #expect(FileManager.default.fileExists(atPath: fixture.directory + "/manifest.json"))
  await #expect(throws: WorkerProtocolError.self) { try await fixture.create() }
  let store = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: fixture.space, runtimeRoot: fixture.root)
  try await store.removeFencedRuntime(socketsInDirectory: false)
  await #expect(throws: WorkerProtocolError.self) { try await fixture.create() }
  try await claim.cleanup()
  #expect(!FileManager.default.fileExists(atPath: fixture.directory))
  try await fixture.create()
}
