import Foundation
import GRDB
import KeelObjectStore
import Scratch
@testable import SpaceCore
import SpaceFS
import Testing

@Suite
struct BlobStoreTests {
  private func folder() throws -> URL {
    let url = try scratchURL("blobs")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func open(_ folder: URL) throws -> Space {
    try Space.open(file: folder.appendingPathComponent("space.sqlite"))
  }

  private func objects(_ folder: URL) -> FileSystemObjectStore {
    FileSystemObjectStore(root: folder.appendingPathComponent("objects"))
  }

  private func stored(_ content: String, in space: Space) async throws -> StoredBlob {
    let hash = Substrate.blobHash(Array(content.utf8))
    return try await space.writer.read { db in try Substrate.storedBlob(hash, in: db) }
  }

  private func filler(_ count: Int, _ seed: String = "x") -> String {
    String(repeating: seed, count: count)
  }

  @Test func smallContentStaysInlineAndRoundTrips() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let space = try open(folder)

    let content = filler(1024, "a")
    _ = try await space.writeText("/notes/small.md", content)

    #expect(try await space.readText("/notes/small.md") == content)
    guard case .inline = try await stored(content, in: space) else {
      Issue.record("small content should stay inline")
      return
    }
    #expect(try await objects(folder).list(ListQuery()).entries.isEmpty)
  }

  @Test func largeContentExternalizesUnderAShardedKeyAndRoundTrips() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let space = try open(folder)

    let content = filler(BlobStore.inlineThreshold + 1)
    _ = try await space.writeText("/big.bin", content)

    #expect(try await space.readText("/big.bin") == content)

    let hash = Substrate.blobHash(Array(content.utf8))
    guard case let .external(key) = try await stored(content, in: space) else {
      Issue.record("large content should externalize")
      return
    }
    #expect(key.raw == "blobs/\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)")
    #expect(try await objects(folder).getBytes(key) == Data(content.utf8))
  }

  @Test func thresholdSplitsInlineFromExternal() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let space = try open(folder)

    let atThreshold = filler(BlobStore.inlineThreshold, "b")
    let overThreshold = filler(BlobStore.inlineThreshold + 1, "c")
    _ = try await space.writeText("/at.bin", atThreshold)
    _ = try await space.writeText("/over.bin", overThreshold)

    guard case .inline = try await stored(atThreshold, in: space) else {
      Issue.record("content at the threshold should stay inline")
      return
    }
    guard case .external = try await stored(overThreshold, in: space) else {
      Issue.record("content past the threshold should externalize")
      return
    }
    #expect(try await space.readText("/at.bin") == atThreshold)
    #expect(try await space.readText("/over.bin") == overThreshold)
  }

  @Test func identicalContentIsStoredOnceOnBothSidesOfTheSplit() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let space = try open(folder)

    let small = filler(64, "s")
    let large = filler(BlobStore.inlineThreshold + 1, "l")
    for path in ["/one.md", "/two.md"] { _ = try await space.writeText(path, small) }
    for path in ["/one.bin", "/two.bin"] { _ = try await space.writeText(path, large) }

    let smallHash = Substrate.blobHash(Array(small.utf8))
    let largeHash = Substrate.blobHash(Array(large.utf8))
    let (inlineRows, externalRows) = try await space.writer.read { db in
      (
        try BlobRow.where { $0.hash.eq(smallHash) }.fetchAll(db).count,
        try BlobObjectRow.where { $0.hash.eq(largeHash) }.fetchAll(db).count,
      )
    }
    #expect(inlineRows == 1)
    #expect(externalRows == 1)
    #expect(try await objects(folder).list(ListQuery()).entries.count == 1)
  }

  @Test func historicalReadsResolveExternalContent() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let space = try open(folder)

    let first = filler(BlobStore.inlineThreshold + 1, "1")
    let second = filler(BlobStore.inlineThreshold + 2, "2")
    let token = try await space.writeText("/history.bin", first)
    _ = try await space.writeText("/history.bin", second)

    let rev = try #require(token.rev)
    #expect(try await space.readText("/history.bin", at: Rev(rev)) == first)

    let (_, entries) = try await space.fs(.shared, at: Rev(rev)).list("/")
    let entry = try #require(entries.first { $0.name == "history.bin" })
    #expect(entry.size == first.utf8.count)
  }

  @Test func databasesPredatingTheLocatorTableStillRead() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("space.sqlite")

    let legacy = "hello from before the split"
    let space = try Space.open(file: file)
    _ = try await space.writeText("/legacy.md", legacy)
    try await space.writer.write { db in try db.execute(sql: "DROP TABLE blob_objects") }

    let reopened = try Space.open(file: file)
    #expect(try await reopened.readText("/legacy.md") == legacy)

    let large = filler(BlobStore.inlineThreshold + 1, "n")
    _ = try await reopened.writeText("/after.bin", large)
    #expect(try await reopened.readText("/after.bin") == large)
    #expect(try await reopened.readText("/legacy.md") == legacy)
  }
}
