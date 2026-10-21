#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import GRDB
import KeelObjectStore
import SpaceFS
import StructuredQueries

// A blob is inline when it has no `blob_objects` row: the absence of a row is
// the "stored in blobs.content" case, so a space database written before this
// table existed reads back correctly with no migration.
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

/// One blob, read a range at a time: the file a path named when it was opened.
struct BlobReader: SpaceFileReader {
  let blobs: BlobStore
  let database: any DatabaseReader
  let hash: String

  func read(at offset: Int, count: Int) async throws -> Data {
    try await blobs.read(hash, at: offset, count: count, in: database)
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

  func write<Value: Sendable>(
    _ writer: any DatabaseWriter,
    emittingTo broadcast: FSBroadcast,
    prefetching: (@Sendable (Database) throws -> [String])? = nil,
    _ body: @Sendable @escaping (Database, BlobCache, inout [MutationEvent]) throws -> Value,
  ) async throws -> Value {
    let result = try await resolving(writer, prefetching: prefetching, { db, cache in
      var pending: [MutationEvent] = []
      let value = try body(db, cache, &pending)
      return Emitting(value: value, events: pending)
    }) { operation in
      try await Substrate.writeEmitting(writer, to: broadcast) { db, pending in
        let result = try operation(db)
        pending += result.events
        return result
      }
    }
    return result.value
  }

  private struct Emitting<Value: Sendable>: Sendable {
    let value: Value
    let events: [MutationEvent]
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

  /// At most `count` bytes of blob `hash` from `offset`, without loading the
  /// rest of it: an inline blob is cut in SQLite, an external one fetched as a
  /// range.
  func read(_ hash: String, at offset: Int, count: Int, in reader: any DatabaseReader) async throws -> Data {
    precondition(offset >= 0 && count >= 0)
    enum Part: Sendable {
      case inline(Data)
      case external(ObjectKey)
    }
    let part = try await reader.read { db -> Part in
      if let key = try Substrate.externalKey(hash, in: db) { return .external(key) }
      guard let row = try Row.fetchOne(
        db, sql: "SELECT substr(content, ?, ?) AS part FROM blobs WHERE hash = ?", arguments: [offset + 1, count, hash],
      ) else { throw SpaceError.notFound(hash) }
      let bytes: Data? = row["part"]
      return .inline(bytes ?? Data())
    }
    switch part {
    case let .inline(data):
      return data
    case let .external(key):
      guard let objects else { throw SpaceError.notFound(key.raw) }
      return try await objects.get(key, bytes: Int64(offset) ..< Int64(offset) + Int64(count))
    }
  }

  private func fetch(_ key: ObjectKey) async throws -> [UInt8] {
    guard let objects else { throw SpaceError.notFound(key.raw) }
    return Array(try await objects.getBytes(key))
  }
}
