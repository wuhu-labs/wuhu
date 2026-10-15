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
  private var opened: [String: (ExecutionWorkerManifestStore, ExecutionWorkerManifest)] = [:]

  init(root: String, space: String) { self.root = root; self.space = space }

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
      let store = try await ExecutionWorkerManifestStore.open(directory: directory, space: space)
      let result = await store.inspectForBoot()
      if case .missing = result { return try await store.hasRuntimeFiles() ? .missingManifest : .missing }
      if case let .manifest(manifest) = result {
        guard manifest.generation == generation else { return .corrupt }
        opened[directory] = (store, manifest)
      }
      return result
    } catch { return .unsafeStorage }
  }

  func cleanup(_ directory: String) async throws {
    guard let (store, manifest) = opened.removeValue(forKey: directory), try await store.load() == manifest else {
      throw WorkerProtocolError(.invalidConfiguration, message: "Execution worker runtime changed during boot fencing")
    }
    try await store.removeFencedRuntime()
  }
}
