import ComposableArchitecture
import SwiftUI
import WuhuAPI

@Reducer
struct AppFeature {
  enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case home
    case channels
    case sessions
    case issues
    case docs

    var id: String {
      rawValue
    }

    var label: String {
      switch self {
      case .home: "Home"
      case .channels: "Channels"
      case .sessions: "Sessions"
      case .issues: "Issues"
      case .docs: "Docs"
      }
    }

    var systemImage: String {
      switch self {
      case .home: "house"
      case .channels: "bubble.left.and.bubble.right"
      case .sessions: "terminal"
      case .issues: "checklist"
      case .docs: "doc.text"
      }
    }
  }

  @ObservableState
  struct State: Equatable {
    var sidebarItem: SidebarItem? = .sessions

    var sessions = SessionsFeature.State()
    var workspace = WorkspaceFeature.State()
    var settings = SettingsFeature.State()

    var selectedSessionID: String?
    var selectedChannelID: String?
    var selectedDocPath: String?

    var sessionDetail: SessionDetailFeature.State?
    var channelDetail: SessionDetailFeature.State?
    var docDetail: WorkspaceDocDetailFeature.State?

    @Presents var createSession: CreateSessionFeature.State?

    var isShowingSettings = false
  }

  enum Action: BindableAction {
    case onAppear
    case scenePhaseChanged(ScenePhase)
    case binding(BindingAction<State>)

    case sessions(SessionsFeature.Action)
    case workspace(WorkspaceFeature.Action)
    case settings(SettingsFeature.Action)
    case sessionDetail(SessionDetailFeature.Action)
    case channelDetail(SessionDetailFeature.Action)
    case docDetail(WorkspaceDocDetailFeature.Action)

    case createSession(PresentationAction<CreateSessionFeature.Action>)
    case createSessionTapped
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

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
          return sidebarItemBecameVisibleEffects(item: state.sidebarItem, state: &state)
        }
        return .merge(
          .send(.sessions(.tabBecameHidden)),
          .send(.workspace(.tabBecameHidden)),
        )

      case .binding(\.sidebarItem):
        clearDetail(&state)
        return sidebarItemBecameVisibleEffects(item: state.sidebarItem, state: &state)

      case .binding(\.selectedSessionID):
        return syncSessionDetail(&state)

      case .binding(\.selectedChannelID):
        return syncChannelDetail(&state)

      case .binding(\.selectedDocPath):
        syncDocDetail(&state)
        return .none

      case let .settings(.delegate(.settingsChanged(settings))):
        let serverURL = settings.selectedServer?.url
        let username = settings.resolvedUsername
        return .merge(
          .send(.sessions(.settingsChanged(serverURL: serverURL, username: username))),
          .send(.workspace(.settingsChanged(serverURL: serverURL))),
        )

      case let .sessions(.delegate(.sessionCreated(session))):
        if session.type == .channel {
          state.sidebarItem = .channels
          state.selectedChannelID = session.id
          return syncChannelDetail(&state)
        } else {
          state.sidebarItem = .sessions
          state.selectedSessionID = session.id
          return syncSessionDetail(&state)
        }

      case .sessionDetail(.delegate(.didClose)):
        state.selectedSessionID = nil
        state.sessionDetail = nil
        return .send(.sessions(.refresh))

      case .channelDetail(.delegate(.didClose)):
        state.selectedChannelID = nil
        state.channelDetail = nil
        return .send(.sessions(.refresh))

      case .createSessionTapped:
        guard let serverURL = state.sessions.serverURL else { return .none }
        state.createSession = .init(serverURL: serverURL, username: state.sessions.username)
        return .none

      case let .createSession(.presented(.delegate(.created(session)))):
        state.createSession = nil
        state.sessions.sessions[id: session.id] = session
        if session.type == .channel {
          state.sidebarItem = .channels
          state.selectedChannelID = session.id
          return .merge(
            .send(.sessions(.refresh)),
            syncChannelDetail(&state),
          )
        } else {
          state.sidebarItem = .sessions
          state.selectedSessionID = session.id
          return .merge(
            .send(.sessions(.refresh)),
            syncSessionDetail(&state),
          )
        }

      case .createSession(.presented(.delegate(.cancelled))):
        state.createSession = nil
        return .none

      case .binding, .sessions, .workspace, .settings,
           .sessionDetail, .channelDetail, .docDetail, .createSession:
        return .none
      }
    }
    .ifLet(\.sessionDetail, action: \.sessionDetail) {
      SessionDetailFeature()
    }
    .ifLet(\.channelDetail, action: \.channelDetail) {
      SessionDetailFeature()
    }
    .ifLet(\.docDetail, action: \.docDetail) {
      WorkspaceDocDetailFeature()
    }
    .ifLet(\.$createSession, action: \.createSession) {
      CreateSessionFeature()
    }
  }

  private func clearDetail(_ state: inout State) {
    state.selectedSessionID = nil
    state.selectedChannelID = nil
    state.selectedDocPath = nil
    state.sessionDetail = nil
    state.channelDetail = nil
    state.docDetail = nil
  }

  private func syncSessionDetail(_ state: inout State) -> Effect<Action> {
    if let id = state.selectedSessionID {
      state.sessionDetail = SessionDetailFeature.State(
        sessionID: id,
        serverURL: state.sessions.serverURL,
        username: state.sessions.username,
      )
    } else {
      state.sessionDetail = nil
    }
    return .none
  }

  private func syncChannelDetail(_ state: inout State) -> Effect<Action> {
    if let id = state.selectedChannelID {
      state.channelDetail = SessionDetailFeature.State(
        sessionID: id,
        serverURL: state.sessions.serverURL,
        username: state.sessions.username,
      )
    } else {
      state.channelDetail = nil
    }
    return .none
  }

  private func syncDocDetail(_ state: inout State) {
    if let path = state.selectedDocPath,
       let serverURL = state.sessions.serverURL
    {
      state.docDetail = WorkspaceDocDetailFeature.State(path: path, serverURL: serverURL)
    } else {
      state.docDetail = nil
    }
  }

  private func sidebarItemBecameVisibleEffects(item: SidebarItem?, state _: inout State) -> Effect<Action> {
    var effects: [Effect<Action>] = []

    let sessionsVisible = item == .sessions || item == .channels
    let workspaceVisible = item == .docs || item == .issues

    if sessionsVisible {
      effects.append(.send(.sessions(.tabBecameVisible)))
    } else {
      effects.append(.send(.sessions(.tabBecameHidden)))
    }

    if workspaceVisible {
      effects.append(.send(.workspace(.tabBecameVisible)))
    } else {
      effects.append(.send(.workspace(.tabBecameHidden)))
    }

    return .merge(effects)
  }
}
