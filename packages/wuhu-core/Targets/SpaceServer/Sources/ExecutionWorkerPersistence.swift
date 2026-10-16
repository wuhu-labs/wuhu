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
import struct WorkerOwner.ParentExecutionIdentity
import class WorkerProtocol.WorkerListener
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
  private var preparation: ImagePreparation?
  var preparationDescriptor: Int32? { preparation?.descriptor }
  private var image: ImageReference?

  init(directory: String, space: String, generation: UUID, incarnation: UUID, location: ExecutionWorkerSocketLocation, store: ExecutionWorkerManifestStore, sockets: ExecutionWorkerSocketDirectory, manifest: ExecutionWorkerManifest? = nil) {
    self.directory = directory; self.space = space; self.generation = generation; self.incarnation = incarnation
    self.location = location; self.store = store; self.sockets = sockets
    self.manifest = manifest; durable = manifest != nil; image = manifest?.image
  }

  static func adoptExec(record: ExecWorkerRecord, manifest: ExecutionWorkerManifest) async throws -> ExecutionWorkerRuntimeStorage {
    guard let location = manifest.sockets, let sockets = try await ExecutionWorkerSocketDirectory.openIfPresent(location, space: record.space, generation: record.generation) else { throw AdminExecError.refused("workerSockets") }
    let store = try await ExecutionWorkerManifestStore.open(directory: record.directory, space: record.space)
    if let image = manifest.image {
      let root = URL(fileURLWithPath: record.directory).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("execution-images").path
      try ImageRetention.transaction(root: root) { try $0.verify(image) }
    }
    let storage = ExecutionWorkerRuntimeStorage(directory: record.directory, space: record.space, generation: record.generation, incarnation: record.incarnation, location: location, store: store, sockets: sockets, manifest: manifest)
    try await storage.pinEndpoints()
    return storage
  }

  func prepareImage(executable: String) async throws -> String {
    guard image == nil, manifest == nil else { throw AdminExecError.refused("workerImageIdentity") }
    let prepared = try ImageRetention.transaction(root: imageRoot) { store in
      try store.prepare(source: URL(fileURLWithPath: executable).resolvingSymlinksInPath().path, id: incarnation, owner: "worker:" + space + ":" + incarnation.uuidString)
    }
    preparation = prepared
    image = prepared.reference
    try await store.savePreparation(.init(version: 1, space: space, generation: generation, location: location, image: prepared.reference))
    return try ImageRetention.transaction(root: imageRoot) { try $0.imagePath(prepared.reference) }
  }

  private var imageRoot: String {
    URL(fileURLWithPath: directory).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("execution-images").path
  }

  func pinEndpoints() async throws { try await sockets.pinEndpoints() }

  func persist(processID: Int32, token: String) async throws {
    guard manifest == nil else { throw WorkerProtocolError(.invalidConfiguration, message: "Execution worker identity was already recorded") }
    let birth = try processBirthIdentity(processID)
    if let reference = image {
      image = try ImageRetention.transaction(root: imageRoot) { try $0.bind(reference, processID: processID, birth: birth) }
    }
    let record = ExecutionWorkerManifest(version: 2, space: space, generation: generation, incarnation: incarnation, processID: processID, birth: birth, credentials: .init(current: token), sockets: location, image: image)
    manifest = record
    try await store.save(record)
    durable = true
    try await store.removePreparation()
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

  func execRecord(fence: UUID, carrier: Int32, listener: WorkerListener.ListenerExport) throws -> ExecWorkerRecord {
    guard durable, let manifest, manifest.credentials.successor == nil else { throw AdminExecError.refused("workerIdentity") }
    try manifest.verifyProcess()
    return .init(directory: directory, space: space, generation: generation, incarnation: incarnation, processID: manifest.processID, birth: manifest.birth, fence: fence, carrier: carrier, listener: listener.descriptor, listenerIdentity: .init(listener.identity))
  }

  func cleanup() async throws {
    if let manifest {
      switch ExecutionWorkerBootProcess.inspect(manifest) {
      case .absent, .differentBirth: break
      case .matching, .unverified: throw WorkerProtocolError(.unavailable, message: "Execution worker exit is unconfirmed; persistence retained")
      }
      guard try await store.load() == (durable ? manifest : nil) else { throw WorkerProtocolError(.invalidConfiguration, message: "Execution worker manifest changed before cleanup") }
    }
    preparation = nil
    let saved = try await store.load()
    let cleanup = try await ExecutionWorkerCleanup.stage(store: store, space: space, generation: generation, location: location, sockets: sockets, manifest: saved, image: image)
    try await cleanup.finish(store: store, sockets: sockets)
  }
}
