import ComposableArchitecture
import SwiftUI

struct AppView: View {
  let store: StoreOf<AppFeature>

  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    TabView(
      selection: Binding(
        get: { store.selectedTab },
        set: { store.send(.tabSelected($0)) },
      ),
    ) {
      SessionsView(store: store.scope(state: \.sessions, action: \.sessions))
        .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }
        .tag(AppFeature.State.Tab.sessions)

      WorkspaceView(store: store.scope(state: \.workspace, action: \.workspace))
        .tabItem { Label("Workspace", systemImage: "square.grid.3x3") }
        .tag(AppFeature.State.Tab.workspace)

      SettingsView(store: store.scope(state: \.settings, action: \.settings))
        .tabItem { Label("Settings", systemImage: "gear") }
        .tag(AppFeature.State.Tab.settings)
    }
    .onAppear { store.send(.onAppear) }
    .onChange(of: scenePhase) { _, newPhase in
      store.send(.scenePhaseChanged(newPhase))
    }
  }
}
