import ComposableArchitecture
import SwiftUI

@main
struct WuhuApp: App {
  let store = withDependencies {
    $0.continuousClock = ContinuousClock()
  } operation: {
    Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  }

  var body: some Scene {
    WindowGroup {
      AppView(store: store)
    }
  }
}
