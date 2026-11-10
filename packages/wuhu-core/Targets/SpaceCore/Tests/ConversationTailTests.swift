import DeterministicDependencies
import SessionDomain
@testable import SpaceCore
import Testing

@Suite(.deterministicDependencies) struct ConversationTailTests {
  @Test func aTailCatchesUpThenHearsEachPostUntilItsViewerStopsReading() async throws {
    let space = try Space.inMemory()
    let store = space.sessions
    try await space.registerPeople(["alice", "bob"])
    let channel = try await store.createConversation(members: ["alice", "bob"], title: "plans", in: .shared)
    func say(_ id: String) async throws {
      _ = try await store.post(.conversation(channel), messageID: .init(id), sender: Sender(id: "alice", timeZone: .gmt), content: .init(text: id))
    }
    try await say("one")
    try await say("two")
    func person(_ name: String) -> Principal {
      Principal(actor: .person(persona: name, account: AccountID(rawValue: name)), group: .shared)
    }
    var tail = store.observeConversation(channel, after: 1, as: person("bob")).makeAsyncIterator()
    #expect(try await tail.next()?.map(\.id.rawValue) == ["two"])
    try await say("three")
    #expect(try await tail.next()?.map(\.id.rawValue) == ["three"])

    try await store.removeChannelMembers(channel, people: ["bob"], as: person("alice"))
    try await say("four")
    do {
      let heard = try await tail.next()
      Issue.record("a viewer who left heard \(String(describing: heard))")
    } catch {
      #expect(error as? SessionStoreError == .unknownConversation(channel.rawValue))
    }
  }

  @Test func aTailOfAConversationItsViewerDoesNotReadIsClosed() async throws {
    let space = try Space.inMemory()
    let store = space.sessions
    try await space.registerPeople(["alice", "bob", "carol"])
    let channel = try await store.createConversation(members: ["alice", "bob"], title: "plans", in: .shared)
    let carol = Principal(actor: .person(persona: "carol", account: AccountID(rawValue: "carol")), group: .shared)
    await #expect(throws: SessionStoreError.unknownConversation(channel.rawValue)) {
      for try await _ in store.observeConversation(channel, as: carol) {}
    }
  }
}
