@testable import SpaceCore
import Testing

@Suite
struct UserProfileTests {
  @Test func aHandleIsStoredLowercasedAndFoundEitherWay() async throws {
    let space = try makeSpace()
    let saved = try await space.setUserProfile(principal: "sail-clock-pepper", handle: "Alice", displayName: "Alice A")
    #expect(saved.handle == "alice")
    #expect(saved.displayName == "Alice A")

    #expect(try await space.userProfile(principal: "sail-clock-pepper") == saved)
    #expect(try await space.userProfile(handle: "ALICE") == saved)
    #expect(try await space.userProfile(handle: "alice") == saved)
    #expect(try await space.userProfile(handle: "bob") == nil)
    #expect(try await space.userProfile(principal: "nobody") == nil)
  }

  @Test func twoPrincipalsCannotShareAHandleInAnyCasing() async throws {
    let space = try makeSpace()
    _ = try await space.setUserProfile(principal: "one", handle: "alice", displayName: nil)
    await #expect(throws: SpaceError.handleTaken("alice")) {
      try await space.setUserProfile(principal: "two", handle: "Alice", displayName: nil)
    }
    #expect(try await space.userProfile(handle: "alice")?.principal == "one")
  }

  @Test func resettingTheSameHandleForTheSamePrincipalSucceeds() async throws {
    let space = try makeSpace()
    _ = try await space.setUserProfile(principal: "one", handle: "alice", displayName: nil)
    let again = try await space.setUserProfile(principal: "one", handle: "alice", displayName: "renamed")
    #expect(again.displayName == "renamed")
    #expect(try await space.userProfiles().count == 1)
  }

  @Test func renamingFreesTheOldHandleForSomeoneElse() async throws {
    let space = try makeSpace()
    _ = try await space.setUserProfile(principal: "one", handle: "alice", displayName: nil)
    _ = try await space.setUserProfile(principal: "one", handle: "alicia", displayName: nil)
    #expect(try await space.userProfile(handle: "alice") == nil)
    #expect(try await space.userProfile(principal: "one")?.handle == "alicia")

    let taken = try await space.setUserProfile(principal: "two", handle: "alice", displayName: nil)
    #expect(taken.principal == "two")
    #expect(try await space.userProfiles().map(\.handle) == ["alice", "alicia"])
  }

  @Test(arguments: ["a", "-alice", "alice_b", "aliceé", String(repeating: "a", count: 33), "", "al ice", "ALICE!"])
  func invalidHandlesAreRefused(_ raw: String) async throws {
    #expect(Handle.normalized(raw) == nil)
    let space = try makeSpace()
    await #expect(throws: SpaceError.invalidHandle(raw)) {
      try await space.setUserProfile(principal: "one", handle: raw, displayName: nil)
    }
  }

  @Test(arguments: ["ab", "a1", String(repeating: "a", count: 32), "a-b-c", "Alice-2"])
  func validHandlesNormalizeToLowercase(_ raw: String) {
    #expect(Handle.normalized(raw) == raw.lowercased())
  }
}
