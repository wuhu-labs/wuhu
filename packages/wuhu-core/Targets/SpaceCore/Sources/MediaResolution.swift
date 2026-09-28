#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif

import SessionDomain
import struct SpaceContract.GroupID
import struct WuhuAI.MediaContent
import protocol WuhuAI.MediaResolver
import enum WuhuAI.ResolvedMedia

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

  func blobBytes(_ hash: String) async throws -> [UInt8] {
    try await blobs.read(writer, prefetching: { _ in [hash] }) { db, cache in
      try cache.blob(of: hash, in: db).content
    }
  }
}

// A media block names its bytes and nothing fetches them until a request is
// actually being built. Returning nil makes the dialects drop the block, which
// would silently move every byte after it, so a reference we own that cannot be
// read throws instead.
// A hostless space file is the reading session's group's.
public struct SpaceMediaResolver: MediaResolver {
  let space: Space
  let limits: ImageLimits
  let group: GroupID

  public init(space: Space, limits: ImageLimits, group: GroupID) {
    self.space = space
    self.limits = limits
    self.group = group
  }

  public func resolve(_ media: MediaContent) async throws -> ResolvedMedia? {
    guard let reference = MediaReference(media.url) else { return nil }
    let data = switch reference {
    case let .blob(hash): Data(try await space.blobBytes(hash))
    case let .spaceFile(path): try await space.attachmentBytes(path, readingIn: group)
    }
    return switch ImageFitting.fit(data, mimeType: media.mimeType, limits: limits) {
    case let .image(fitted, mimeType): .data(fitted, mimeType: mimeType)
    case let .note(note): .text(note)
    }
  }
}
