import DeterministicDependencies
import Foundation
import Scratch
import SpaceCore
import Testing

@Test(.deterministicDependencies) func closingSpaceEndsObservationKindsAndRefusesNewOnes() async throws {
  let space = try Space.inMemory()
  let query = await space.observeQuery("SELECT path FROM docs", throttle: .zero, as: .shared(.anonymous))
  var queryRows = query.makeAsyncIterator()
  #expect(try await queryRows.next() != nil)
  let live = await space.observeFS(glob: "**", group: .shared)
  let replay = await space.observeFS(glob: "**", from: Rev(0), group: .shared)
  try await space.close()
  #expect(try await queryRows.next() == nil)
  var liveEvents = live.makeAsyncIterator()
  var replayEvents = replay.makeAsyncIterator()
  #expect(await liveEvents.next() == nil)
  #expect(await replayEvents.next() == nil)
  let refused = await space.observeFS(glob: "**", group: .shared)
  var refusedEvents = refused.makeAsyncIterator()
  #expect(await refusedEvents.next() == nil)
  try await space.close()
}

@Test(.deterministicDependencies) func closingSpaceReleasesDatabaseHandlesWhileStoresAreRetained() async throws {
  let folder = try ScratchFolder("space-close")
  let file = folder.url.appendingPathComponent("space.sqlite")
  let space = try Space.open(file: file)
  let sessions = space.sessions
  let identity = try await space.identity()
  _ = try await space.query("SELECT path FROM docs", as: .shared(.anonymous))
  #if os(Linux)
    func databaseHandles() throws -> [String] {
      try FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd").compactMap { fd in
        do {
          let target = try FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/fd/" + fd)
          return target.hasPrefix(file.path) ? target : nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
          return nil
        }
      }
    }
    let opened = try databaseHandles()
    for suffix in ["", "-wal", "-shm"] { #expect(opened.contains(file.path + suffix)) }
  #endif
  try await space.close()
  try await space.close()
  #if os(Linux)
    #expect(try databaseHandles().isEmpty)
  #endif
  let reopened = try Space.open(file: file)
  #expect(try await reopened.identity() == identity)
  try await reopened.close()
  withExtendedLifetime(sessions) {}
}
