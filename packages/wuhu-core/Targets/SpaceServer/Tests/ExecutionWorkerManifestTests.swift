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

private struct ManifestFixture {
  let directory: String
  init() throws {
    let resolved = try #require(realpath("/tmp", nil))
    defer { free(resolved) }
    directory = String(cString: resolved) + "/wm-" + String(UUID().uuidString.prefix(12))
    #expect(mkdir(directory, 0o700) == 0)
  }

  func clean() { try? FileManager.default.removeItem(atPath: directory) }
  var manifest: ExecutionWorkerManifest {
    .init(version: 1, space: "space", generation: UUID(), incarnation: UUID(), processID: getpid(), birth: "test-process-birth-identity", credentials: .init(current: String(repeating: "a", count: 72)))
  }

  func writeFile(_ data: Data, mode: mode_t = 0o600) throws {
    let file = open(directory + "/manifest.json", O_WRONLY | O_CREAT | O_EXCL, mode)
    #expect(file >= 0)
    defer { _ = close(file) }
    #expect(data.withUnsafeBytes { write(file, $0.baseAddress, $0.count) } == data.count)
  }
}

@Test func workerManifestRoundTripRotationAndCleanExitRemoval() async throws {
  let fixture = try ManifestFixture()
  defer { fixture.clean() }
  let store = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space")
  #expect(try await store.load() == nil)
  var manifest = fixture.manifest
  try await store.save(manifest)
  #expect(try await store.load() == manifest)
  manifest.credentials.successor = String(repeating: "b", count: 72)
  try await store.save(manifest)
  #expect(try await store.load() == manifest)
  manifest.credentials = .init(current: try #require(manifest.credentials.successor))
  try await store.save(manifest)
  #expect(try await store.load() == manifest)
  try await store.remove()
  #expect(try await store.load() == nil)
  try await store.remove()
}

@Test func workerManifestRefusesUnsafeExistingDirectoryAndFileWithoutTightening() async throws {
  let fixture = try ManifestFixture()
  defer { fixture.clean() }
  #expect(chmod(fixture.directory, 0o755) == 0)
  await #expect(throws: WorkerProtocolError.self) { try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space") }
  var state = stat()
  #expect(lstat(fixture.directory, &state) == 0 && state.st_mode & 0o777 == 0o755)
  #expect(chmod(fixture.directory, 0o700) == 0)
  let store = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space")
  try fixture.writeFile(JSONEncoder().encode(fixture.manifest), mode: 0o644)
  await #expect(throws: WorkerProtocolError.self) { try await store.load() }
  await #expect(throws: WorkerProtocolError.self) { try await store.save(fixture.manifest) }
  await #expect(throws: WorkerProtocolError.self) { try await store.remove() }
  #expect(lstat(fixture.directory + "/manifest.json", &state) == 0 && state.st_mode & 0o777 == 0o644)
}

@Test(arguments: ["symlink", "hardlink", "fifo", "oversize", "malformed"])
func workerManifestRefusesHostileFiles(kind: String) async throws {
  let fixture = try ManifestFixture()
  defer { fixture.clean() }
  let store = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space")
  let file = fixture.directory + "/manifest.json"
  switch kind {
  case "symlink": #expect(symlink("/dev/null", file) == 0)
  case "hardlink":
    try fixture.writeFile(JSONEncoder().encode(fixture.manifest))
    #expect(link(file, fixture.directory + "/other") == 0)
  case "fifo": #expect(mkfifo(file, 0o600) == 0)
  case "oversize": try fixture.writeFile(Data(repeating: 1, count: 8193))
  default: try fixture.writeFile(Data("secret-that-must-not-appear-in-errors".utf8))
  }
  do { _ = try await store.load(); Issue.record("Unsafe manifest was accepted") }
  catch {
    #expect(String(describing: error).contains("secret-that-must-not-appear-in-errors") == false)
  }
  if kind != "malformed" { await #expect(throws: WorkerProtocolError.self) { try await store.save(fixture.manifest) } }
}

@Test func workerManifestPinsDirectoryAndRefusesRenamedOrSymlinkedPath() async throws {
  let fixture = try ManifestFixture()
  defer { fixture.clean(); try? FileManager.default.removeItem(atPath: fixture.directory + "-moved") }
  let store = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space")
  try await store.save(fixture.manifest)
  #expect(rename(fixture.directory, fixture.directory + "-moved") == 0)
  #expect(mkdir(fixture.directory, 0o700) == 0)
  await #expect(throws: WorkerProtocolError.self) { try await store.load() }
  await #expect(throws: WorkerProtocolError.self) { try await store.save(fixture.manifest) }
  #expect(rmdir(fixture.directory) == 0)
  #expect(symlink(fixture.directory + "-moved", fixture.directory) == 0)
  await #expect(throws: WorkerProtocolError.self) { try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "space") }
}

@Test func workerManifestRejectsForeignSpaceAndPIDReuse() async throws {
  let fixture = try ManifestFixture()
  defer { fixture.clean() }
  let store = try await ExecutionWorkerManifestStore.open(directory: fixture.directory, space: "foreign")
  await #expect(throws: WorkerProtocolError.self) { try await store.save(fixture.manifest) }
  #expect(throws: WorkerProtocolError.self) { try fixture.manifest.verifyProcess(probe: { _ in "another-birth-identity" }) }
  try fixture.manifest.verifyProcess(probe: { _ in "test-process-birth-identity" })
  let birth = try processBirthIdentity(getpid())
  #expect(try processBirthIdentity(getpid()) == birth)
  #expect(throws: WorkerProtocolError.self) { try processBirthIdentity(-1) }
  #expect(throws: WorkerProtocolError.self) { try processBirthIdentity(Int32.max) }
}

@Test func workerManifestDescriptionsNeverRevealCredentials() throws {
  let fixture = try ManifestFixture()
  defer { fixture.clean() }
  var manifest = fixture.manifest
  manifest.credentials.successor = String(repeating: "b", count: 72)
  for rendered in [String(describing: manifest), String(reflecting: manifest), String(describing: manifest.credentials), String(reflecting: manifest.credentials)] {
    #expect(!rendered.contains(manifest.credentials.current))
    #expect(!rendered.contains(try #require(manifest.credentials.successor)))
  }
}

@Test func workerManifestStillReadsTheOriginalVersionOneWireShape() throws {
  let fixture = try ManifestFixture()
  defer { fixture.clean() }
  let original = fixture.manifest
  let json = "{\"version\":1,\"space\":\"space\",\"generation\":\"" + original.generation.uuidString + "\",\"incarnation\":\"" + original.incarnation.uuidString + "\",\"processID\":" + String(original.processID) + ",\"birth\":\"" + original.birth + "\",\"credentials\":{\"current\":\"" + original.credentials.current + "\"}}"
  let decoded = try JSONDecoder().decode(ExecutionWorkerManifest.self, from: Data(json.utf8))
  #expect(decoded == original)
  #expect(decoded.sockets == nil)
  #expect(decoded.workerSocket(directory: fixture.directory) == fixture.directory + "/worker.sock")
  try decoded.validate(directory: fixture.directory, space: "space")
  #expect(throws: WorkerProtocolError.self) { try decoded.validate(directory: "/" + String(repeating: "long-path/", count: 20), space: "space") }
}
