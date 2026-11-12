#if canImport(FoundationEssentials)
  import FoundationEssentials
#else
  import Foundation
#endif
import SessionDomain
import Testing

@Suite struct CacheWarmingTests {
  @Test(arguments: ["cache-warming", "context-pressure"])
  func emptyDecorationsHaveNoLine(_ subscription: String) {
    let item = Fix.notification(kind: .context, subscription: subscription, text: "")
    #expect(item.lines(session: Fix.session).isEmpty)
    #expect(item.cacheWarmingOrigin == nil)
  }

  @Test func scopeNoticeKeepsItsEffectsWithoutRenderingEmptyText() {
    let notice = ScopeContext(folders: ["machines://box/repo": nil], text: "").notice(id: UUID(), at: Fix.instant)
    #expect(TranscriptItem.notification(notice).lines(session: Fix.session).isEmpty)
    #expect(notice.folderRoots?.keys.contains("machines://box/repo") == true)
  }

  @Test func unansweredWarmingNoticeDoesNotRaiseTheFloor() {
    let input = Fix.message(text: "hi").lines(session: Fix.session)
    let warming = Fix.notification(kind: .context, subscription: "cache-warming", text: String(repeating: "a", count: 4000)).lines(session: Fix.session)
    let threshold = input.estimatedContextTokens(images: .claude) + 1
    #expect(!(input + warming).reachesCacheWarmingFloor(threshold, images: .claude))
    let reply = Fix.assistant(totalTokens: threshold).lines(session: Fix.session)
    #expect((input + warming + reply).reachesCacheWarmingFloor(threshold, images: .claude))
  }

  @Test func cacheWarmingOriginComesOnlyFromMeaningfulInputs() {
    #expect(Fix.message().cacheWarmingOrigin == false)
    #expect(Fix.notification().cacheWarmingOrigin == false)
    #expect(Fix.context([:], text: "scope").cacheWarmingOrigin == nil)
    #expect(Fix.assistant(totalTokens: 1).cacheWarmingOrigin == nil)
    #expect(Fix.notification(kind: .context, subscription: "cache-warming", text: "ping").cacheWarmingOrigin == true)
  }
}
