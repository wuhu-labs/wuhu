#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import GRDB
import SessionDomain
import struct SpaceContract.GroupID

extension Space {
  public func storeImage(_ data: Data) async throws -> String {
    let blob = try await blobs.stage(Array(data))
    try await writer.write { db in try Substrate.record(blob, in: db) }
    return blob.hash
  }

  // Only the kernel's own request path gets to defer image bytes to a
  // resolver; everything else is handed them.
  public func imageBytes(_ image: ImageContent) async throws -> Data {
    switch image.source {
    case let .inline(data): data
    case let .blob(hash): Data(try await blobBytes(hash))
    }
  }

  public func mediaBytes(_ reference: MediaReference, group: GroupID) async throws -> Data {
    switch reference {
    case let .blob(hash): Data(try await blobBytes(hash))
    case let .spaceFile(path): try await attachmentBytes(path, readingIn: group)
    }
  }

  public func blobBytes(_ hash: String) async throws -> [UInt8] {
    try await blobs.read(writer, prefetching: { _ in [hash] }) { db, cache in
      try cache.blob(of: hash, in: db).content
    }
  }
}
