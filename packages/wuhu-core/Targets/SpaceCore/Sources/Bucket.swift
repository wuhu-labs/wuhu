#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import KeelObjectStore
import SpaceFS
import StructuredQueries
import Wuwei
import WuweiQueries

/// Bytes the host holds outside any step: their hash, and the object key when they are past the inline tier.
struct Blob: Sendable {
  let hash: String
  let content: [UInt8]
  let externalKey: ObjectKey?
}

/// The bytes a host transaction has at hand, named by the hashes it read: it cannot fetch one itself, so a hash
/// it needs and does not hold means the world moved since the read, and the attempt runs again.
struct BlobContents: Sendable {
  private let loaded: [String: [UInt8]]

  struct Missing: Error {
    let hash: String
  }

  init(_ loaded: [String: [UInt8]] = [:]) {
    self.loaded = loaded
  }

  func bytes(of hash: String) throws -> [UInt8] {
    guard let content = loaded[hash] else { throw Missing(hash: hash) }
    return content
  }
}

@Table("bucket_objects")
struct BucketObjectRow {
  @Column("hash", primaryKey: true) var hash: String
  @Column("size") var size: Int64
  @Column("line_count") var lineCount: Int64?
  @Column("content") var content: [UInt8]?
  @Column("object_key") var objectKey: String?
}

/// A blob whose bytes are inline or in the object store, as a step reads it on its own connection.
enum StoredBlob: Sendable {
  case inline([UInt8])
  case external(ObjectKey)
}

/// Content-addressed bytes, grow-only: `put` names them by SHA-256, nothing deletes one, and a hash names the
/// same bytes for the life of the space. The step that first names a hash writes its row on its own connection;
/// a caller with no step to ride in reaches the door, `put(_:)`.
struct Bucket: Sendable {
  static let inlineThreshold = 256 * 1024

  let runtime: SpaceRuntime
  let objects: (any ObjectStore)?

  static func key(for hash: String) throws -> ObjectKey {
    try ObjectKey("blobs/\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)")
  }

  /// The row naming `blob`, if the bucket has none yet. Inline bytes carry no line count: it is counted from
  /// them when asked, as external rows' bytes are not at hand to count.
  static func put(_ blob: Blob, in db: inout Database) throws {
    if let key = blob.externalKey {
      let lineCount = Substrate.lineCount(blob.content).map { Value.integer(Int64($0)) } ?? .null
      try db.execute(
        "INSERT OR IGNORE INTO bucket_objects (hash, size, line_count, content, object_key) VALUES (?, ?, ?, NULL, ?)",
        .text(blob.hash), .integer(Int64(blob.content.count)), lineCount, .text(key.raw),
      )
    } else {
      try db.execute(
        "INSERT OR IGNORE INTO bucket_objects (hash, size, line_count, content, object_key) VALUES (?, ?, NULL, ?, NULL)",
        .text(blob.hash), .integer(Int64(blob.content.count)), .blob(blob.content),
      )
    }
  }

  /// `hash`'s row as a step reads it: a hash a head, version or attachment names has one, written in the step that
  /// named it, and nothing deletes it.
  static func stored(_ hash: String, in db: Database) throws -> StoredBlob {
    guard let row = row(hash, in: db) else { preconditionFailure("a named hash has its bucket row: \(hash)") }
    guard let raw = row.objectKey else { return .inline(row.content!) }
    return .external(try ObjectKey(raw))
  }

  static func row(_ hash: String, in db: Database) -> BucketObjectRow? {
    db.rows(BucketObjectRow.where { $0.hash.eq(hash) }).first
  }

  /// `content` under its hash, in the space's object store when it is past the inline tier; the row is the
  /// caller's step.
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

  /// Puts `content` and answers its hash, for a caller with no step to ride in: the bytes go to the object store
  /// first, and one step of the Space cell records the row.
  func put(_ content: [UInt8]) async throws -> String {
    let blob = try await stage(content)
    _ = try await runtime.worker().call(SpaceCell.ID("space")) { try $0.put(blob) }
    return blob.hash
  }

  /// `hash`'s bytes, from its row or from the object store.
  func bytes(_ hash: String) async throws -> [UInt8] {
    try await blob(hash).content
  }

  /// The bytes of each of `hashes`, for a host transaction that has none of its own.
  func contents(of hashes: [String]) async throws -> BlobContents {
    var loaded: [String: [UInt8]] = [:]
    for hash in hashes where loaded[hash] == nil {
      loaded[hash] = try await bytes(hash)
    }
    return BlobContents(loaded)
  }

  /// `hash`'s bytes, with the object key of the ones past the inline tier.
  func blob(_ hash: String) async throws -> Blob {
    let row = try await object(hash)
    switch (row.content, row.objectKey) {
    case let (content?, nil): return Blob(hash: hash, content: content, externalKey: nil)
    case let (nil, raw?):
      let key = try ObjectKey(raw)
      guard let objects else { throw SpaceError.notFound(raw) }
      return Blob(hash: hash, content: Array(try await objects.getBytes(key)), externalKey: key)
    default: preconditionFailure("a bucket row holds its bytes inline or under an object key: \(hash)")
    }
  }

  /// At most `count` bytes of `hash` from `offset`, without loading the rest of it. SQLite answers NULL for a
  /// substring of a zero-length blob, which an empty file's row holds.
  func read(_ hash: String, at offset: Int, count: Int) async throws -> Data {
    precondition(offset >= 0 && count >= 0)
    guard let row = runtime.worker().cell(SpaceCell.ID("space")).bucketRange(hash, offset, count) else {
      throw SpaceError.notFound(hash)
    }
    guard let raw = row["object_key"].text else { return Data(row["part"].blob ?? []) }
    let key = try ObjectKey(raw)
    guard let objects else { throw SpaceError.notFound(raw) }
    return try await objects.get(key, bytes: Int64(offset) ..< Int64(offset) + Int64(count))
  }

  /// The size of `hash`'s bytes and their line count, counted from the bytes when they are inline.
  func measure(_ hash: String) async throws -> (size: Int64, lineCount: Int64?) {
    let row = try await object(hash)
    guard let content = row.content else { return (row.size, row.lineCount) }
    return (row.size, Substrate.lineCount(content).map(Int64.init))
  }

  private func object(_ hash: String) async throws -> BucketObjectRow {
    guard let row = runtime.worker().cell(SpaceCell.ID("space")).bucket(hash) else { throw SpaceError.notFound(hash) }
    return row
  }
}

/// One blob, read a range at a time: the file a path named when it was opened.
struct BucketReader: SpaceFileReader {
  let bucket: Bucket
  let hash: String

  func read(at offset: Int, count: Int) async throws -> Data {
    try await bucket.read(hash, at: offset, count: count)
  }
}

extension SpaceCell {
  /// Records `blob`'s row: the step that first names a hash writes it.
  @discardableResult
  mutating func put(_ blob: Blob) throws -> String {
    try Bucket.put(blob, in: &db)
    return blob.hash
  }

  /// A bucket row, its bytes included.
  func bucket(_ hash: String) -> BucketObjectRow? {
    Bucket.row(hash, in: db)
  }

  /// The object key of `hash`'s row (`NULL` for inline bytes) and the range of its content asked for.
  func bucketRange(_ hash: String, _ offset: Int, _ count: Int) -> Row? {
    db.rows(
      "SELECT object_key, substr(content, ?, ?) AS part FROM bucket_objects WHERE hash = ?",
      .integer(Int64(offset + 1)), .integer(Int64(count)), .text(hash),
    ).first
  }
}
