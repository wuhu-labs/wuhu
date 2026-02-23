import ComposableArchitecture
import SwiftUI

@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    enum Tab: Hashable {
      case sessions
      case workspace
      case settings
    }

    var selectedTab: Tab = .sessions
    var sessions = SessionsFeature.State()
    var workspace = WorkspaceFeature.State()
    var settings = SettingsFeature.State()
  }

  enum Action {
    case onAppear
    case scenePhaseChanged(ScenePhase)
    case tabSelected(State.Tab)
    case sessions(SessionsFeature.Action)
    case workspace(WorkspaceFeature.Action)
    case settings(SettingsFeature.Action)
  }

  var body: some ReducerOf<Self> {
    Scope(state: \.sessions, action: \.sessions) {
      SessionsFeature()
    }
    Scope(state: \.workspace, action: \.workspace) {
      WorkspaceFeature()
    }
    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Reduce { state, action in
      switch action {
      case .onAppear:
        return .send(.settings(.onAppear))

      case let .scenePhaseChanged(phase):
        if phase == .active {
          return selectedTabBecameVisibleEffects(tab: state.selectedTab)
        }
        return .merge(
          .send(.sessions(.tabBecameHidden)),
          .send(.workspace(.tabBecameHidden)),
        )

      case let .tabSelected(tab):
        state.selectedTab = tab
        return selectedTabBecameVisibleEffects(tab: tab)

      case let .settings(.delegate(.settingsChanged(settings))):
        return .merge(
          .send(
            .sessions(
              .settingsChanged(
                serverURL: settings.selectedServer?.url,
                username: settings.resolvedUsername,
              ),
            ),
          ),
          .send(
            .workspace(
              .settingsChanged(serverURL: settings.selectedServer?.url),
            ),
          ),
        )

      case .sessions, .workspace, .settings:
        return .none
      }
    }
  }

  private func selectedTabBecameVisibleEffects(tab: State.Tab) -> Effect<Action> {
    switch tab {
    case .sessions:
      .merge(
        .send(.sessions(.tabBecameVisible)),
        .send(.workspace(.tabBecameHidden)),
      )
    case .workspace:
      .merge(
        .send(.workspace(.tabBecameVisible)),
        .send(.sessions(.tabBecameHidden)),
      )
    case .settings:
      .merge(
        .send(.sessions(.tabBecameHidden)),
        .send(.workspace(.tabBecameHidden)),
      )
    }
  }
}
