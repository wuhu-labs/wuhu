#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SpaceCore
import SpaceFS
import Testing

struct TrustedImportTests {
  @Test func tableCreationAndPopulationRecordTheirAttributionAtomically() async throws {
    let space = try Space.inMemory()
    let marker = RevisionAttribution(actor: "import", via: "/destination.table")
    let table = try SpacePath(validating: "/staged.table")
    let created = try await space.createTable(table, header: TableHeader(columns: []), in: .shared, acting: .shared, attribution: marker)
    let rows = try await space.commitRows(table, [.insert([])], in: .shared, acting: .shared, attribution: marker)
    let recorded = try await space.attributions(of: [created, rows.rev])
    #expect(recorded == [created: marker, rows.rev: marker])
  }

  @Test func emptyDirectoryRemovalNeverRecursesOrRemovesNonDirectories() async throws {
    let space = try Space.inMemory()
    let fs = await space.fs(.shared)
    _ = try await space.writeFile(SpacePath(validating: "/folder/child"), data: Data("keep".utf8), in: .shared, acting: .shared, ifMatch: nil, createOnly: true)
    let revision = try await space.currentRevision()
    #expect(try await !space.removeEmptyDirectory(SpacePath(validating: "/folder"), in: .shared, acting: .shared))
    #expect(try await space.currentRevision() == revision)
    #expect(try await fs.read("/folder/child").1 == Data("keep".utf8))
    await #expect(throws: SpaceError.notADirectory("/folder/child")) {
      _ = try await space.removeEmptyDirectory(SpacePath(validating: "/folder/child"), in: .shared, acting: .shared)
    }
    try await fs.delete("/folder/child", ifMatch: nil)
    #expect(try await space.removeEmptyDirectory(SpacePath(validating: "/folder"), in: .shared, acting: .shared))
    await #expect(throws: SpaceError.notFound("/folder")) { _ = try await fs.stat("/folder") }
    await #expect(throws: SpaceError.alreadyExists("/")) { _ = try await space.removeEmptyDirectory(SpacePath(validating: "/"), in: .shared, acting: .shared) }
  }
}
