import DeterministicDependencies
import Foundation
import GRDB
import KeelObjectStore
import Scratch
@testable import SpaceCore
import SpaceFS
import Testing
import Wuwei

@Suite(.deterministicDependencies)
struct BucketTests {
  private func folder() throws -> URL {
    let url = try scratchURL("bucket")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func open(_ folder: URL) throws -> Space {
    try Space.open(file: folder.appendingPathComponent("space.sqlite"))
  }

  private func objects(_ folder: URL) -> FileSystemObjectStore {
    FileSystemObjectStore(root: folder.appendingPathComponent("objects"))
  }

  private func stored(_ content: String, in space: Space) async throws -> Blob {
    try await space.bucket.blob(Substrate.blobHash(Array(content.utf8)))
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
    #expect(try await stored(content, in: space).externalKey == nil, "small content should stay inline")
    #expect(try await objects(folder).list(ListQuery()).entries.isEmpty)
    try await space.close()
  }

  @Test func largeContentExternalizesUnderAShardedKeyAndRoundTrips() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let space = try open(folder)

    let content = filler(Bucket.inlineThreshold + 1)
    _ = try await space.writeText("/big.bin", content)

    #expect(try await space.readText("/big.bin") == content)

    let hash = Substrate.blobHash(Array(content.utf8))
    let key = try #require(try await stored(content, in: space).externalKey)
    #expect(key.raw == "blobs/\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)")
    #expect(try await objects(folder).getBytes(key) == Data(content.utf8))
    try await space.close()
  }

  @Test func thresholdSplitsInlineFromExternal() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let space = try open(folder)

    let atThreshold = filler(Bucket.inlineThreshold, "b")
    let overThreshold = filler(Bucket.inlineThreshold + 1, "c")
    _ = try await space.writeText("/at.bin", atThreshold)
    _ = try await space.writeText("/over.bin", overThreshold)

    #expect(try await stored(atThreshold, in: space).externalKey == nil, "content at the threshold should stay inline")
    #expect(try await stored(overThreshold, in: space).externalKey != nil, "content past the threshold should externalize")
    #expect(try await space.readText("/at.bin") == atThreshold)
    #expect(try await space.readText("/over.bin") == overThreshold)
    try await space.close()
  }

  @Test func identicalContentIsStoredOnceOnBothSidesOfTheSplit() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let space = try open(folder)

    let small = filler(64, "s")
    let large = filler(Bucket.inlineThreshold + 1, "l")
    for path in ["/one.md", "/two.md"] { _ = try await space.writeText(path, small) }
    for path in ["/one.bin", "/two.bin"] { _ = try await space.writeText(path, large) }

    let cell = space.worker.cell(SpaceCell.ID("space"))
    let smallHash = Substrate.blobHash(Array(small.utf8))
    let largeHash = Substrate.blobHash(Array(large.utf8))
    #expect(cell.bucket(smallHash)?.content == Array(small.utf8))
    #expect(cell.bucket(largeHash)?.content == nil)
    #expect(cell.bucket(largeHash)?.size == Int64(large.utf8.count))
    #expect(try await objects(folder).list(ListQuery()).entries.count == 1)
    try await space.close()
  }

  @Test func historicalReadsResolveExternalContent() async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let space = try open(folder)

    let first = filler(Bucket.inlineThreshold + 1, "1")
    let second = filler(Bucket.inlineThreshold + 2, "2")
    let token = try await space.writeText("/history.bin", first)
    _ = try await space.writeText("/history.bin", second)

    let rev = try #require(token.rev)
    #expect(try await space.readText("/history.bin", at: Rev(rev)) == first)

    let (_, entries) = try await space.fs(.shared, at: Rev(rev)).list("/")
    let entry = try #require(entries.first { $0.name == "history.bin" })
    #expect(entry.size == first.utf8.count)
    try await space.close()
  }

  @Test(arguments: [1024, Bucket.inlineThreshold + 1])
  func aReaderReadsRangesOfTheFileAsItWasOpened(_ size: Int) async throws {
    let folder = try folder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let space = try open(folder)
    let content = Data((0 ..< size).map { UInt8(truncatingIfNeeded: $0 * 7) })
    let token = try await space.fs(.shared).write("/file.bin", content, ifMatch: nil)
    let reader = try await space.fs(.shared).reader("/file.bin")
    _ = try await space.fs(.shared).write("/file.bin", Data("later".utf8), ifMatch: nil)
    #expect(try await reader.read(at: 0, count: 5) == content.prefix(5))
    #expect(try await reader.read(at: size - 3, count: 10) == content.suffix(3))
    #expect(try await reader.read(at: size, count: 10).isEmpty)
    #expect(try await reader.read(at: 100, count: 0).isEmpty)
    let past = try await space.fs(.shared, at: Rev(try #require(token.rev))).reader("/file.bin")
    #expect(try await past.read(at: 500, count: 200) == content.dropFirst(500).prefix(200))
    try await space.close()
  }
}
