import protocol MainHub.Main
import enum MainHub.MainContractError
#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import MainHub
import SessionDomain
import SpaceCore
import Testing

@Suite struct HubContractTests {
  @Test func executionHydrationRefusesReservedSessionsButPlainReadsRemainAvailable() async throws {
    let space = try Space.inMemory()
    let main: any Main = Hub(space: space)
    let id = try await space.sessions.createSession(group: .shared, title: "reserved", kind: .agent, createdBy: "morgan", model: .init(provider: "test", model: "test", effort: "high"))
    let reservation = UUID()
    try await space.sessions.reserveForArchive(id, token: reservation)
    await #expect(throws: ExecutionHydrationError.reservedForArchive(id)) { try await main.hydrate(id) }
    #expect(try await space.sessions.hydrate(id).record.id == id)
    space.sessions.releaseArchiveReservation(id, token: reservation)
    #expect(try await main.hydrate(id).record.id == id)
  }

  @Test func constructionIsInertAndSessionCallsUseTheRealStore() async throws {
    let model = ModelSpecifier(provider: "test", model: "test", effort: "high")
    let space = try Space.inMemory()
    let before = try await space.currentRevision()
    var access = SessionAccess()
    access.beforeHydrate = { _ in throw MainContractError.unexpectedReply }
    let main: any Main = Hub(space: space, sessionAccess: access)
    #expect(try await space.currentRevision() == before)
    let id = try await space.sessions.createSession(group: .shared, title: "hub", kind: .agent, createdBy: "morgan", model: model)
    await #expect(throws: MainContractError.unexpectedReply) { try await main.hydrate(id) }
    let input = QueueInput.notification(.init(id: UUID(), timestamp: Date(), kind: .timer, subscriptionID: .init("clock"), content: .init(text: "wake")))
    let position = try await main.append(id, .inputEnqueued(input)).value(Int.self)
    #expect(position == 1)
    #expect(try await main.queueHead(id) == 1)
    #expect(try await main.record(id) == space.sessions.record(id))
    #expect(try await main.modelRoute(id) == nil)
    #expect(try await main.pendingCommand(id) == nil)
    try await space.sessions.requestCommand(id, .compact(instructions: "retain"))
    #expect(try await main.pendingCommand(id) == .compact(instructions: "retain"))
    let generation = try await space.sessions.hydrate(id).generation
    _ = try #require(try await main.claimCompactRequest(id, generation: generation))
    #expect(try await main.registeredSubscriptions(id).ids.isEmpty)
    let drain = try await main.drainQueue(id)
    #expect(!drain.items.isEmpty)
    #expect(try await space.sessions.undrainedInputs(id).isEmpty)
    _ = try await main.append(id, .interrupted)
    _ = try await main.append(id, .resumed)
    _ = try await main.append(id, .compactionActivity(.active))
    _ = try await main.append(id, .compactionActivity(.inactive))
    _ = try await space.sessions.archive(id, grace: .seconds(60))
    #expect(try await main.record(id).lifecycle != .live)
    _ = try await space.sessions.unarchive(id)
    #expect(try await main.record(id).lifecycle == .live)
    _ = try await main.append(id, .interrupted)
    _ = try await space.sessions.restart(id)
    #expect(try await main.record(id).executor == .kernel(model))
  }
}
