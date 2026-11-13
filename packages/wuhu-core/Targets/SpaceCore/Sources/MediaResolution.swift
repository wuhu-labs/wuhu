#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import SessionDomain
import struct SpaceContract.GroupID

extension Space {
  public func storeImage(_ data: Data) async throws -> String {
    try await bucket.put(Array(data))
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
    try await bucket.bytes(hash)
  }
}
