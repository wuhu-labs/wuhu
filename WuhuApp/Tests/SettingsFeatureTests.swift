import ComposableArchitecture
@testable import WuhuApp
import XCTest

final class SettingsFeatureTests: XCTestCase {
  func testOnAppearLoadsAndDelegates() async {
    let server = ServerConfig(id: UUID(), name: "Prod", urlString: "https://wuhu.example.com")
    let settings = AppSettings(servers: [server], selectedServerID: server.id, username: "alice")

    let store = TestStore(initialState: SettingsFeature.State()) {
      SettingsFeature()
    } withDependencies: {
      $0.appSettingsClient = AppSettingsClient(
        load: { settings },
        save: { _ in },
      )
    }

    await store.send(.onAppear) {
      $0.servers = IdentifiedArray(uniqueElements: [server])
      $0.selectedServerID = server.id
      $0.username = "alice"
    }
    await store.receive(\.delegate, .settingsChanged(settings))
  }
}
