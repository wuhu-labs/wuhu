#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import Fetch

public struct ObjectKey: Hashable, Sendable, CustomStringConvertible {
  public let raw: String

  public init(_ raw: String) throws {
    guard Self.isValid(raw) else { throw ObjectStoreError.invalidKey(raw) }
    self.raw = raw
  }

  public var description: String { self.raw }

  static func isValid(_ raw: String) -> Bool {
    if raw.isEmpty { return false }
    for scalar in raw.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
      return false
    }
    for segment in raw.split(separator: "/", omittingEmptySubsequences: false) {
      if segment.isEmpty || segment == "." || segment == ".." { return false }
    }
    return true
  }
}

public struct ObjectMetadata: Hashable, Sendable {
  public var contentLength: Int64?
  public var contentType: String?
  public var etag: String?

  public init(contentLength: Int64? = nil, contentType: String? = nil, etag: String? = nil) {
    self.contentLength = contentLength
    self.contentType = contentType
    self.etag = etag
  }
}

public struct GetResult: Sendable {
  public var body: Body
  public var metadata: ObjectMetadata

  public init(body: Body, metadata: ObjectMetadata) {
    self.body = body
    self.metadata = metadata
  }
}

public struct ListQuery: Hashable, Sendable {
  public var prefix: String
  public var continuationToken: String?
  public var maxKeys: Int?

  public init(prefix: String = "", continuationToken: String? = nil, maxKeys: Int? = nil) {
    if let maxKeys {
      precondition(maxKeys > 0, "ListQuery.maxKeys must be positive")
    }
    self.prefix = prefix
    self.continuationToken = continuationToken
    self.maxKeys = maxKeys
  }
}

public struct ObjectListEntry: Hashable, Sendable {
  public var key: ObjectKey
  public var size: Int64

  public init(key: ObjectKey, size: Int64) {
    self.key = key
    self.size = size
  }
}

public struct ObjectListing: Hashable, Sendable {
  public var entries: [ObjectListEntry]
  public var continuationToken: String?

  public init(entries: [ObjectListEntry], continuationToken: String? = nil) {
    self.entries = entries
    self.continuationToken = continuationToken
  }

  public var isTruncated: Bool { self.continuationToken != nil }
}

public enum ObjectStoreError: Error, Sendable, Equatable {
  case invalidKey(String)
  case notFound(ObjectKey)
  case unexpectedStatus(code: Int, message: String?)
  case malformedResponse(String)
}

public protocol ObjectStore: Sendable {
  func put(_ key: ObjectKey, body: Body) async throws
  func get(_ key: ObjectKey) async throws -> GetResult
  func head(_ key: ObjectKey) async throws -> ObjectMetadata?
  func delete(_ key: ObjectKey) async throws
  func list(_ query: ListQuery) async throws -> ObjectListing
}

extension ObjectStore {
  public func put(_ key: ObjectKey, bytes: Data, contentType: String? = nil) async throws {
    try await self.put(key, body: .bytes(bytes, contentType: contentType))
  }

  public func getBytes(_ key: ObjectKey, upTo limit: Int? = nil) async throws -> Data {
    try await self.get(key).body.bytes(upTo: limit)
  }

  public func exists(_ key: ObjectKey) async throws -> Bool {
    try await self.head(key) != nil
  }
}
