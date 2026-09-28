import Fetch
import Foundation
import KeelObjectStore
import Testing

@Suite struct FileSystemObjectStoreContractTests {
  private func withContract(_ body: (ObjectStoreContract) async throws -> Void) async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("keel-fs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try await body(ObjectStoreContract(capabilities: .init(preservesContentType: false)) {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      return FileSystemObjectStore(root: root)
    })
  }

  @Test func putGetRoundTrip() async throws { try await self.withContract { try await $0.putGetRoundTrip() } }
  @Test func overwrite() async throws { try await self.withContract { try await $0.overwrite() } }
  @Test func deleteIdempotence() async throws { try await self.withContract { try await $0.deleteIdempotence() } }
  @Test func missingKeyError() async throws { try await self.withContract { try await $0.missingKeyError() } }
  @Test func existence() async throws { try await self.withContract { try await $0.existence() } }
  @Test func listOrderingAndPagination() async throws { try await self.withContract { try await $0.listOrderingAndPagination() } }
}

@Suite struct FileSystemObjectStoreBehaviorTests {
  private func freshRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("keel-fs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  @Test func storesNestedKeysAsPlainFilesWithoutContentType() async throws {
    let root = try self.freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileSystemObjectStore(root: root)
    let key = try ObjectKey("wal/2026/000001.wal")
    try await store.put(key, body: .bytes(Data("frame".utf8), contentType: "application/octet-stream"))

    let result = try await store.get(key)
    #expect(try await result.body.bytes() == Data("frame".utf8))
    #expect(result.metadata.contentType == nil)
  }

  @Test func deletePrunesEmptyDirectories() async throws {
    let root = try self.freshRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileSystemObjectStore(root: root)
    let key = try ObjectKey("logs/2026/07/20.log")
    try await store.put(key, bytes: Data("line".utf8))
    try await store.delete(key)

    let listing = try await store.list(ListQuery(prefix: "logs/"))
    #expect(listing.entries.isEmpty)
  }
}
