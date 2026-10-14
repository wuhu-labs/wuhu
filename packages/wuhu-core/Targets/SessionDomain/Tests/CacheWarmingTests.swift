import Foundation
import SessionDomain
import Testing

@Suite struct CacheWarmingTests {
  @Test(arguments: ["cache-warming", "context-pressure"])
  func canceledWarmingDecorationsAreNotWork(_ subscription: String) {
    let notice = SystemNotification(id: UUID(), timestamp: Date(), kind: .context, subscriptionID: .init(subscription), content: .init(text: ""))
    #expect(!Transcript(items: [.notification(notice)]).hasWork)
  }

  @Test func emptyScopeNoticeStillCarriesWorkAndFolderEffects() {
    let notice = ScopeContext(folders: ["machines://box/repo": nil], text: "").notice(id: UUID(), at: Date())
    #expect(Transcript(items: [.notification(notice)]).hasWork)
    #expect(notice.folderRoots?.keys.contains("machines://box/repo") == true)
  }
}
