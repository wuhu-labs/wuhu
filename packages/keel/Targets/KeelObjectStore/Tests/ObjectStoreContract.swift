#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch
import KeelObjectStore

struct ObjectStoreContract: Sendable {
  struct Capabilities: Sendable {
    var preservesContentType: Bool

    init(preservesContentType: Bool) {
      self.preservesContentType = preservesContentType
    }
  }

  struct Failure: Error, CustomStringConvertible {
    let message: String
    var description: String { self.message }
  }

  let makeStore: @Sendable () async throws -> any ObjectStore
  let capabilities: Capabilities

  init(
    capabilities: Capabilities,
    makeStore: @escaping @Sendable () async throws -> any ObjectStore,
  ) {
    self.capabilities = capabilities
    self.makeStore = makeStore
  }

  func runAll() async throws {
    try await self.putGetRoundTrip()
    try await self.overwrite()
    try await self.deleteIdempotence()
    try await self.missingKeyError()
    try await self.existence()
    try await self.listOrderingAndPagination()
  }

  func putGetRoundTrip() async throws {
    let store = try await self.makeStore()
    let key = try self.key("hello.txt", in: Self.freshNamespace())
    let payload = Data("hello object store".utf8)
    try await store.put(key, body: .bytes(payload, contentType: "text/plain"))

    let result = try await store.get(key)
    let readBack = try await result.body.bytes()
    try expectEqual(readBack, payload, "round-trip bytes")

    if self.capabilities.preservesContentType {
      try expectEqual(result.metadata.contentType, "text/plain", "round-trip content-type")
    }

    let metadata = try await store.head(key)
    try expect(metadata != nil, "head returns metadata for an existing key")
    try expectEqual(metadata?.contentLength, Int64(payload.count), "head content-length")

    try? await store.delete(key)
  }

  func overwrite() async throws {
    let store = try await self.makeStore()
    let key = try self.key("mutable", in: Self.freshNamespace())
    try await store.put(key, bytes: Data("first".utf8))
    try await store.put(key, bytes: Data("second-longer".utf8))
    try expectEqual(
      try await store.getBytes(key),
      Data("second-longer".utf8),
      "overwrite, longer over shorter",
    )

    try await store.put(key, bytes: Data("tiny".utf8))
    try expectEqual(
      try await store.getBytes(key),
      Data("tiny".utf8),
      "overwrite, shorter over longer leaves no stale tail",
    )

    try? await store.delete(key)
  }

  func deleteIdempotence() async throws {
    let store = try await self.makeStore()
    let key = try self.key("removable", in: Self.freshNamespace())
    try await store.put(key, bytes: Data("payload".utf8))

    try await store.delete(key)
    try expect(try await store.exists(key) == false, "deleted key no longer exists")
    try await store.delete(key)

    do {
      _ = try await store.get(key)
      throw Failure(message: "get after delete should throw notFound")
    } catch let error as ObjectStoreError {
      guard case .notFound = error else {
        throw Failure(message: "expected notFound, got \(error)")
      }
    }
  }

  func missingKeyError() async throws {
    let store = try await self.makeStore()
    let key = try self.key("absent", in: Self.freshNamespace())
    do {
      _ = try await store.get(key)
      throw Failure(message: "get on missing key should throw notFound")
    } catch let error as ObjectStoreError {
      guard case .notFound = error else {
        throw Failure(message: "expected notFound, got \(error)")
      }
    }
  }

  func existence() async throws {
    let store = try await self.makeStore()
    let key = try self.key("existence", in: Self.freshNamespace())
    try expect(try await store.exists(key) == false, "missing key does not exist")
    try expect(try await store.head(key) == nil, "missing key has no metadata")

    try await store.put(key, bytes: Data("here".utf8))
    try expect(try await store.exists(key) == true, "present key exists")

    try? await store.delete(key)
  }

  func listOrderingAndPagination() async throws {
    let store = try await self.makeStore()
    let prefix = Self.freshNamespace() + "/list/"

    let insertionOrder = ["gamma", "alpha", "delta", "beta", "epsilon"]
    for name in insertionOrder {
      let key = try ObjectKey(prefix + name)
      try await store.put(key, bytes: Data(name.utf8))
    }
    let expected = insertionOrder.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }

    var collected: [ObjectListEntry] = []
    var token: String? = nil
    var pages = 0
    repeat {
      let listing = try await store.list(
        ListQuery(prefix: prefix, continuationToken: token, maxKeys: 2),
      )
      try expect(listing.entries.count <= 2, "page honors maxKeys")
      collected.append(contentsOf: listing.entries)
      token = listing.continuationToken
      pages += 1
      try expect(pages <= 10, "pagination terminates")
    } while token != nil

    try expect(pages >= 2, "small maxKeys forces multiple pages")

    let names = collected.map { String($0.key.raw.dropFirst(prefix.count)) }
    try expectEqual(names, expected, "listing is prefix-scoped and byte-ordered")

    for entry in collected {
      let name = String(entry.key.raw.dropFirst(prefix.count))
      try expectEqual(entry.size, Int64(name.utf8.count), "list entry reports object size")
    }

    for name in insertionOrder {
      try? await store.delete(ObjectKey(prefix + name))
    }
  }

  private static func freshNamespace() -> String {
    "keel-contract-" + UUID().uuidString.lowercased()
  }

  private func key(_ suffix: String, in namespace: String) throws -> ObjectKey {
    try ObjectKey(namespace + "/" + suffix)
  }
}

private func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
  if !condition {
    throw ObjectStoreContract.Failure(message: message())
  }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) throws {
  if actual != expected {
    throw ObjectStoreContract.Failure(message: "\(label): expected \(expected), got \(actual)")
  }
}
