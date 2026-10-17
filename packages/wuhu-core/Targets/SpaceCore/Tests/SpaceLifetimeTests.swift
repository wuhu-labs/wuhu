import SpaceCore
import Testing

@Test func closingSpaceEndsObservationKindsAndRefusesNewOnes() async throws {
  let space = try Space.inMemory()
  let query = await space.observeQuery("SELECT path FROM docs", throttle: .zero, as: .shared(.anonymous))
  var queryRows = query.makeAsyncIterator()
  #expect(try await queryRows.next() != nil)
  let live = await space.observeFS(glob: "**", group: .shared)
  let replay = await space.observeFS(glob: "**", from: Rev(0), group: .shared)
  await space.close()
  #expect(try await queryRows.next() == nil)
  var liveEvents = live.makeAsyncIterator()
  var replayEvents = replay.makeAsyncIterator()
  #expect(await liveEvents.next() == nil)
  #expect(await replayEvents.next() == nil)
  let refused = await space.observeFS(glob: "**", group: .shared)
  var refusedEvents = refused.makeAsyncIterator()
  #expect(await refusedEvents.next() == nil)
  await space.close()
}
