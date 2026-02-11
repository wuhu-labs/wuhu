import ComposableArchitecture
import Foundation
import WuhuAPI
import WuhuClient

@Reducer
struct SessionsFeature {
  @ObservableState
  struct State: Equatable {
    var serverURL: URL?
    var username: String?

    var sessions: IdentifiedArrayOf<WuhuSession> = []
    var isLoading = false
    var error: String?

    var path = StackState<SessionDetailFeature.State>()
    @Presents var createSession: CreateSessionFeature.State?
  }

  enum Action {
    case onAppear
    case onDisappear

    case tabBecameVisible
    case tabBecameHidden
    case settingsChanged(serverURL: URL?, username: String?)

    case refresh
    case refreshResponse(TaskResult<[WuhuSession]>)

    case createButtonTapped
    case createSession(PresentationAction<CreateSessionFeature.Action>)

    case path(StackAction<SessionDetailFeature.State, SessionDetailFeature.Action>)
  }

  @Dependency(\.continuousClock) private var clock
  @Dependency(\.wuhuClientProvider) private var wuhuClientProvider

  private enum CancelID {
    case refreshTimer
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        return .send(.tabBecameVisible)

      case .onDisappear:
        return .cancel(id: CancelID.refreshTimer)

      case .tabBecameVisible:
        return .merge(
          .send(.refresh),
          refreshTimerEffect(),
        )

      case .tabBecameHidden:
        return .cancel(id: CancelID.refreshTimer)

      case let .settingsChanged(serverURL, username):
        state.serverURL = serverURL
        state.username = username
        return .send(.refresh)

      case .refresh:
        guard let serverURL = state.serverURL else {
          state.error = "Select a server in Settings."
          state.sessions = []
          return .none
        }
        state.isLoading = true
        state.error = nil
        return .run { send in
          await send(
            .refreshResponse(
              TaskResult {
                try await wuhuClientProvider.make(serverURL).listSessions()
              },
            ),
          )
        }

      case let .refreshResponse(.success(sessions)):
        state.isLoading = false
        state.error = nil
        state.sessions = IdentifiedArray(uniqueElements: sessions.sorted(by: { $0.updatedAt > $1.updatedAt }))
        return .none

      case let .refreshResponse(.failure(error)):
        state.isLoading = false
        state.error = "\(error)"
        return .none

      case .createButtonTapped:
        guard let serverURL = state.serverURL else { return .none }
        state.createSession = .init(serverURL: serverURL, username: state.username)
        return .none

      case let .createSession(.presented(.delegate(.created(session)))):
        state.createSession = nil
        state.sessions[id: session.id] = session
        state.path.append(.init(sessionID: session.id, serverURL: sessionServerURL(state: state), username: state.username))
        return .send(.refresh)

      case .createSession(.presented(.delegate(.cancelled))):
        state.createSession = nil
        return .none

      case .createSession:
        return .none

      case let .path(.element(_, .delegate(.didClose))):
        return .send(.refresh)

      case .path:
        return .none
      }
    }
    .ifLet(\.$createSession, action: \.createSession) {
      CreateSessionFeature()
    }
    .forEach(\.path, action: \.path) {
      SessionDetailFeature()
    }
  }

  private func sessionServerURL(state: State) -> URL {
    state.serverURL ?? URL(string: "http://127.0.0.1:5530")!
  }

  private func refreshTimerEffect() -> Effect<Action> {
    .run { send in
      for await _ in clock.timer(interval: .seconds(60)) {
        await send(.refresh)
      }
    }
    .cancellable(id: CancelID.refreshTimer, cancelInFlight: true)
  }
}
