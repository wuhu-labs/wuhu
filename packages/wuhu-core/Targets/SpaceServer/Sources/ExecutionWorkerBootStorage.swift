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

actor ExecutionWorkerBootStorage {
  let root: String
  let space: String
  private let runtimeRoot: String
  private enum Opened {
    case runtime(ExecutionWorkerManifestStore, ExecutionWorkerManifest, ExecutionWorkerSocketDirectory?)
    case preparation(ExecutionWorkerManifestStore, ExecutionWorkerPreparation, ExecutionWorkerSocketDirectory)
    case cleanup(ExecutionWorkerManifestStore, ExecutionWorkerCleanup, ExecutionWorkerSocketDirectory?)
  }

  private var opened: [String: Opened] = [:]

  init(root: String, space: String, runtimeRoot: String = ExecutionWorkerSocketLocation.runtimeRoot) { self.root = root; self.space = space; self.runtimeRoot = runtimeRoot }

  func inventory() async -> ExecutionWorkerBootFence.Inventory {
    let images = URL(fileURLWithPath: root).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("execution-images").path
    if FileManager.default.fileExists(atPath: images) {
      do { try ImageRetention.transaction(root: images) { _ in } }
      catch { return .unsafeStorage(images) }
    }
    var state = stat()
    if lstat(root, &state) != 0, errno == ENOENT { return .missing }
    let descriptor: Int32
    do { descriptor = try ExecutionWorkerManifestStore.openDirectory(root) }
    catch { return .unsafeStorage(root) }
    guard let entries = fdopendir(descriptor) else { _ = close(descriptor); return .unsafeStorage(root) }
    defer { _ = closedir(entries) }
    var directories: [String] = []
    errno = 0
    while let entry = readdir(entries) {
      let name = withUnsafePointer(to: entry.pointee.d_name) {
        $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) { String(cString: $0) }
      }
      if name != ".", name != ".." { directories.append(root + "/" + name) }
      errno = 0
    }
    guard errno == 0 else { return .unsafeStorage(root) }
    return .directories(directories.sorted())
  }

  func read(_ directory: String) async -> ExecutionWorkerBootFence.Read {
    guard let generation = UUID(uuidString: String(directory.dropFirst(root.count + 1))), directory.hasPrefix(root + "/") else { return .unsafeStorage }
    do {
      let store = try await ExecutionWorkerManifestStore.open(directory: directory, space: space, runtimeRoot: runtimeRoot)
      if let cleanup = try await store.loadCleanup() {
        try cleanup.validate(space: space, generation: generation, runtimeRoot: runtimeRoot)
        let sockets = try await cleanup.openClaim(runtimeRoot: runtimeRoot)
        let manifest = try await store.load()
        if let manifest {
          guard manifest.generation == generation, manifest.sockets == cleanup.location else { return .unsafeStorage }
        }
        opened[directory] = .cleanup(store, cleanup, sockets)
        return .cleanup(manifest?.credentials)
      }
      let result = await store.inspectForBoot()
      if case .missing = result {
        if let preparation = try await store.loadPreparation() {
          guard try await store.preparationImage(preparation.image) == nil else { return .missingManifest }
          if try await ExecutionWorkerSocketDirectory.openIfPresent(preparation.location, space: space, generation: generation, runtimeRoot: runtimeRoot) == nil {
            _ = try await ExecutionWorkerSocketDirectory.create(space: space, generation: generation, runtimeRoot: runtimeRoot)
          }
          guard let sockets = try await ExecutionWorkerSocketDirectory.openIfPresent(preparation.location, space: space, generation: generation, runtimeRoot: runtimeRoot) else { return .unsafeStorage }
          opened[directory] = .preparation(store, preparation, sockets)
          return .cleanup(nil)
        }
        return try await store.hasRuntimeFiles() ? .missingManifest : .missing
      }
      if case let .manifest(manifest) = result {
        guard manifest.generation == generation else { return .corrupt }
        let sockets: ExecutionWorkerSocketDirectory?
        if let location = manifest.sockets {
          sockets = try await ExecutionWorkerSocketDirectory.openIfPresent(location, space: space, generation: generation, runtimeRoot: runtimeRoot)
        } else { sockets = nil }
        opened[directory] = .runtime(store, manifest, sockets)
      }
      return result
    } catch { return .unsafeStorage }
  }

  func cleanup(_ directory: String) async throws {
    guard let opened = opened.removeValue(forKey: directory) else {
      throw WorkerProtocolError(.invalidConfiguration, message: "Execution worker runtime was not inspected")
    }
    let store: ExecutionWorkerManifestStore
    let manifest: ExecutionWorkerManifest
    var claim: ExecutionWorkerSocketDirectory?
    switch opened {
    case let .preparation(store, preparation, sockets):
      guard try await store.preparationImage(preparation.image) == nil else { throw WorkerProtocolError(.unavailable, message: "Worker preparation is still live") }
      let record = try await ExecutionWorkerCleanup.stage(store: store, space: space, generation: preparation.generation, location: preparation.location, sockets: sockets, manifest: nil, image: preparation.image)
      try await record.finish(store: store, sockets: sockets)
      return
    case let .cleanup(store, record, sockets):
      try await record.finish(store: store, sockets: sockets)
      return
    case let .runtime(savedStore, savedManifest, sockets):
      store = savedStore; manifest = savedManifest; claim = sockets
    }
    guard try await store.load() == manifest else {
      throw WorkerProtocolError(.invalidConfiguration, message: "Execution worker runtime changed during boot fencing")
    }
    try await store.validateFencedRuntime(socketsInDirectory: manifest.sockets == nil)
    if let location = manifest.sockets {
      if claim == nil {
        // Exclusive allocation closes the missing-runtime race; retain the key through canonical deletion.
        _ = try await ExecutionWorkerSocketDirectory.create(space: space, generation: manifest.generation, runtimeRoot: runtimeRoot)
        claim = try await ExecutionWorkerSocketDirectory.openIfPresent(location, space: space, generation: manifest.generation, runtimeRoot: runtimeRoot)
      }
      guard let claim else { throw WorkerProtocolError(.invalidConfiguration, message: "Execution worker cleanup claim disappeared") }
      let cleanup = try await ExecutionWorkerCleanup.stage(store: store, space: space, generation: manifest.generation, location: location, sockets: claim, manifest: manifest)
      try await cleanup.finish(store: store, sockets: claim)
    } else {
      try await store.removeFencedRuntime()
    }
  }
}
