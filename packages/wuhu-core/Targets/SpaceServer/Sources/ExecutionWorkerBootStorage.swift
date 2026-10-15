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

actor ExecutionWorkerBootStorage {
  let root: String
  let space: String
  private let runtimeRoot: String
  private var opened: [String: (ExecutionWorkerManifestStore, ExecutionWorkerManifest, ExecutionWorkerSocketDirectory?)] = [:]

  init(root: String, space: String, runtimeRoot: String = ExecutionWorkerSocketLocation.runtimeRoot) { self.root = root; self.space = space; self.runtimeRoot = runtimeRoot }

  func inventory() async -> ExecutionWorkerBootFence.Inventory {
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
      let result = await store.inspectForBoot()
      if case .missing = result { return try await store.hasRuntimeFiles() ? .missingManifest : .missing }
      if case let .manifest(manifest) = result {
        guard manifest.generation == generation else { return .corrupt }
        let sockets: ExecutionWorkerSocketDirectory?
        if let location = manifest.sockets {
          sockets = try await ExecutionWorkerSocketDirectory.openIfPresent(location, space: space, generation: generation, runtimeRoot: runtimeRoot)
        } else { sockets = nil }
        opened[directory] = (store, manifest, sockets)
      }
      return result
    } catch { return .unsafeStorage }
  }

  func cleanup(_ directory: String) async throws {
    guard let (store, manifest, sockets) = opened.removeValue(forKey: directory), try await store.load() == manifest else {
      throw WorkerProtocolError(.invalidConfiguration, message: "Execution worker runtime changed during boot fencing")
    }
    try await store.validateFencedRuntime(socketsInDirectory: manifest.sockets == nil)
    var claim = sockets
    if let location = manifest.sockets, claim == nil {
      // Exclusive allocation closes the missing-runtime race; retain the key through canonical deletion.
      _ = try await ExecutionWorkerSocketDirectory.create(space: space, generation: manifest.generation, runtimeRoot: runtimeRoot)
      claim = try await ExecutionWorkerSocketDirectory.openIfPresent(location, space: space, generation: manifest.generation, runtimeRoot: runtimeRoot)
      guard claim != nil else { throw WorkerProtocolError(.invalidConfiguration, message: "Execution worker cleanup claim disappeared") }
    }
    try await claim?.removeEndpoints()
    try await store.removeFencedRuntime(socketsInDirectory: manifest.sockets == nil)
    try await claim?.cleanup()
  }
}
