#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import GRDB
import KeelObjectStore
import StructuredQueries

// A blob is inline when it has no `blob_objects` row: the absence of a row is
// the "stored in blobs.content" case, so a space database written before this
// table existed reads back correctly with no migration.
let blobObjectSchemaSQL = """
CREATE TABLE IF NOT EXISTS "blob_objects" (
  "hash" TEXT NOT NULL PRIMARY KEY,
  "object_key" TEXT NOT NULL,
  "size" INTEGER NOT NULL,
  "line_count" INTEGER
);
"""

@Table("blob_objects")
struct BlobObjectRow {
  @Column("hash", primaryKey: true) var hash: String
  @Column("object_key") var objectKey: String
  @Column("size") var size: Int64
  @Column("line_count") var lineCount: Int64?
}

struct Blob: Sendable {
  let hash: String
  let content: [UInt8]
  let externalKey: ObjectKey?
}

enum StoredBlob: Sendable {
  case inline([UInt8])
  case external(ObjectKey)
}

struct BlobCache: Sendable {
  private let loaded: [String: [UInt8]]

  init(_ loaded: [String: [UInt8]] = [:]) {
    self.loaded = loaded
  }

  func blob(of hash: String, in db: Database) throws -> Blob {
    switch try Substrate.storedBlob(hash, in: db) {
    case let .inline(content):
      Blob(hash: hash, content: content, externalKey: nil)
    case let .external(key):
      if let content = loaded[hash] {
        Blob(hash: hash, content: content, externalKey: key)
      } else {
        throw BlobStore.Deferred(hash: hash, key: key)
      }
    }
  }
}

struct BlobStore: Sendable {
  static let inlineThreshold = 256 * 1024

  let objects: (any ObjectStore)?

  struct Deferred: Error {
    let hash: String
    let key: ObjectKey
  }

  static func key(for hash: String) throws -> ObjectKey {
    try ObjectKey("blobs/\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)")
  }

  func stage(_ content: [UInt8]) async throws -> Blob {
    try await stage(content, hash: Substrate.blobHash(content))
  }

  func stage(_ content: [UInt8], hash: String) async throws -> Blob {
    guard content.count > Self.inlineThreshold, let objects else {
      return Blob(hash: hash, content: content, externalKey: nil)
    }
    let key = try Self.key(for: hash)
    if try await objects.head(key) == nil {
      try await objects.put(key, bytes: Data(content))
    }
    return Blob(hash: hash, content: content, externalKey: key)
  }

  func read<T: Sendable>(
    _ reader: any DatabaseReader,
    prefetching: (@Sendable (Database) throws -> [String])? = nil,
    _ body: @Sendable @escaping (Database, BlobCache) throws -> T,
  ) async throws -> T {
    try await resolving(reader, prefetching: prefetching, body) { try await reader.read($0) }
  }

  func write<T: Sendable>(
    _ writer: any DatabaseWriter,
    prefetching: (@Sendable (Database) throws -> [String])? = nil,
    _ body: @Sendable @escaping (Database, BlobCache) throws -> T,
  ) async throws -> T {
    try await resolving(writer, prefetching: prefetching, body) { try await writer.write($0) }
  }

  // External content cannot be fetched inside a database transaction, so the
  // body runs against a cache and aborts the transaction the first time it
  // needs a blob the cache lacks. Each retry loads that blob, so the loop makes
  // progress on every pass; `prefetching` collapses the bulk cases to one pass.
  private func resolving<T: Sendable>(
    _ reader: any DatabaseReader,
    prefetching: (@Sendable (Database) throws -> [String])?,
    _ body: @Sendable @escaping (Database, BlobCache) throws -> T,
    in transaction: (@Sendable @escaping (Database) throws -> T) async throws -> T,
  ) async throws -> T {
    var loaded: [String: [UInt8]] = [:]
    if let prefetching {
      let external = try await reader.read { db in
        try prefetching(db).compactMap { hash -> (String, ObjectKey)? in
          try Substrate.externalKey(hash, in: db).map { (hash, $0) }
        }
      }
      for (hash, key) in external where loaded[hash] == nil {
        loaded[hash] = try await fetch(key)
      }
    }
    while true {
      do {
        let cache = BlobCache(loaded)
        return try await transaction { db in try body(db, cache) }
      } catch let deferred as Deferred {
        loaded[deferred.hash] = try await fetch(deferred.key)
      }
    }
  }

  private func fetch(_ key: ObjectKey) async throws -> [UInt8] {
    guard let objects else { throw SpaceError.notFound(key.raw) }
    return Array(try await objects.getBytes(key))
  }
}
