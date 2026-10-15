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
import struct WorkerOwner.ParentExecutionIdentity
import struct WorkerProtocol.WorkerProtocolError

struct ExecutionWorkerPersistence: Sendable {
  let configDirectory: String
  let space: String
  var runtimeRoot: String = ExecutionWorkerSocketLocation.runtimeRoot

  func allocate(incarnation: UUID) async throws -> ExecutionWorkerRuntimeStorage {
    guard !space.isEmpty, space != ".", space != "..", !space.contains("/"), !space.utf8.contains(0) else { throw Self.unsafeStorage() }
    let workers = try Self.createDirectory(parent: configDirectory, name: "workers", parentPrivate: false)
    let root = try Self.createDirectory(parent: workers, name: space)
    let generation = UUID()
    let directory = root + "/" + generation.uuidString
    let store = try await ExecutionWorkerManifestStore.create(root: root, generation: generation, space: space, runtimeRoot: runtimeRoot)
    let location = try await ExecutionWorkerSocketDirectory.create(space: space, generation: generation, runtimeRoot: runtimeRoot)
    guard let sockets = try await ExecutionWorkerSocketDirectory.openIfPresent(location, space: space, generation: generation, runtimeRoot: runtimeRoot) else { throw Self.unsafeStorage() }
    return ExecutionWorkerRuntimeStorage(directory: directory, space: space, generation: generation, incarnation: incarnation, location: location, store: store, sockets: sockets)
  }

  private static func createDirectory(parent: String, name: String, parentPrivate: Bool = true) throws -> String {
    let descriptor = try ExecutionWorkerManifestStore.openDirectory(parent, requirePrivate: parentPrivate)
    defer { _ = close(descriptor) }
    var state = stat()
    guard fstat(descriptor, &state) == 0, state.st_uid == geteuid(), state.st_mode & 0o022 == 0 else { throw unsafeStorage() }
    guard mkdirat(descriptor, name, 0o700) == 0 || errno == EEXIST else { throw unsafeStorage() }
    let path = parent + "/" + name
    let child = try ExecutionWorkerManifestStore.openDirectory(path)
    defer { _ = close(child) }
    guard fsync(descriptor) == 0 else { throw unsafeStorage() }
    return path
  }

  private static func unsafeStorage() -> WorkerProtocolError {
    .init(.invalidConfiguration, message: "Execution worker persistence requires intact private storage")
  }
}

actor ExecutionWorkerRuntimeStorage {
  nonisolated let directory: String
  nonisolated let location: ExecutionWorkerSocketLocation
  private let space: String
  private let generation: UUID
  private let incarnation: UUID
  private let store: ExecutionWorkerManifestStore
  private let sockets: ExecutionWorkerSocketDirectory
  private var manifest: ExecutionWorkerManifest?
  private var durable = false

  init(directory: String, space: String, generation: UUID, incarnation: UUID, location: ExecutionWorkerSocketLocation, store: ExecutionWorkerManifestStore, sockets: ExecutionWorkerSocketDirectory) {
    self.directory = directory; self.space = space; self.generation = generation; self.incarnation = incarnation
    self.location = location; self.store = store; self.sockets = sockets
  }

  func pinEndpoints() async throws { try await sockets.pinEndpoints() }

  func persist(processID: Int32, token: String) async throws {
    guard manifest == nil else { throw WorkerProtocolError(.invalidConfiguration, message: "Execution worker identity was already recorded") }
    let record = ExecutionWorkerManifest(version: 2, space: space, generation: generation, incarnation: incarnation, processID: processID, birth: try processBirthIdentity(processID), credentials: .init(current: token), sockets: location)
    manifest = record
    try await store.save(record)
    durable = true
  }

  func admit(processID: Int32) async throws {
    guard durable, let manifest, manifest.processID == processID else { throw WorkerProtocolError(.unauthorized, message: "Execution worker admission identity mismatch") }
    try manifest.verifyProcess()
    try await pinEndpoints()
  }

  func checkpointIdentity() throws -> ParentExecutionIdentity {
    guard durable, let manifest else { throw WorkerProtocolError(.unavailable, message: "Execution worker identity is unavailable") }
    try manifest.verifyProcess()
    return .init(space: manifest.space, generation: manifest.generation, incarnation: manifest.incarnation, processID: manifest.processID, birth: manifest.birth)
  }

  func cleanup() async throws {
    if let manifest {
      switch ExecutionWorkerBootProcess.inspect(manifest) {
      case .absent, .differentBirth: break
      case .matching, .unverified: throw WorkerProtocolError(.unavailable, message: "Execution worker exit is unconfirmed; persistence retained")
      }
      guard try await store.load() == manifest else { throw WorkerProtocolError(.invalidConfiguration, message: "Execution worker manifest changed before cleanup") }
    }
    let cleanup = try await ExecutionWorkerCleanup.stage(store: store, space: space, generation: generation, location: location, sockets: sockets, manifest: manifest)
    try await cleanup.finish(store: store, sockets: sockets)
  }
}
