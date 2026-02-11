import ComposableArchitecture
import SwiftUI

@Reducer
struct AppFeature {
  @ObservableState
  struct State: Equatable {
    enum Tab: Hashable {
      case sessions
      case settings
    }

    var selectedTab: Tab = .sessions
    var sessions = SessionsFeature.State()
    var settings = SettingsFeature.State()
  }

  enum Action {
    case onAppear
    case scenePhaseChanged(ScenePhase)
    case tabSelected(State.Tab)
    case sessions(SessionsFeature.Action)
    case settings(SettingsFeature.Action)
  }

  var body: some ReducerOf<Self> {
    Scope(state: \.sessions, action: \.sessions) {
      SessionsFeature()
    }
    Scope(state: \.settings, action: \.settings) {
      SettingsFeature()
    }

    Reduce { state, action in
      switch action {
      case .onAppear:
        return .send(.settings(.onAppear))

      case let .scenePhaseChanged(phase):
        if phase == .active, state.selectedTab == .sessions {
          return .send(.sessions(.tabBecameVisible))
        }
        return .send(.sessions(.tabBecameHidden))

      case let .tabSelected(tab):
        state.selectedTab = tab
        if tab == .sessions {
          return .send(.sessions(.tabBecameVisible))
        }
        return .send(.sessions(.tabBecameHidden))

      case let .settings(.delegate(.settingsChanged(settings))):
        return .send(
          .sessions(
            .settingsChanged(
              serverURL: settings.selectedServer?.url,
              username: settings.resolvedUsername,
            ),
          ),
        )

      case .sessions, .settings:
        return .none
      }
    }
  }
}
