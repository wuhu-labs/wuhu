import ComposableArchitecture
import Foundation
import WuhuAPI
import WuhuClient

@Reducer
struct WorkspaceFeature {
  @ObservableState
  struct State: Equatable {
    var serverURL: URL?

    var docs: IdentifiedArrayOf<WuhuWorkspaceDocSummary> = []
    var isLoading = false
    var error: String?

    var searchText: String = ""
    var filterKey: String?
    var filterValue: String?
  }

  enum Action: BindableAction {
    case onAppear
    case onDisappear

    case tabBecameVisible
    case tabBecameHidden
    case settingsChanged(serverURL: URL?)

    case refresh
    case refreshResponse(TaskResult<[WuhuWorkspaceDocSummary]>)

    case clearFilter
    case setFilter(key: String, value: String)

    case binding(BindingAction<State>)
  }

  @Dependency(\.continuousClock) private var clock
  @Dependency(\.wuhuClientProvider) private var wuhuClientProvider

  private enum CancelID {
    case refreshTimer
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

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

      case let .settingsChanged(serverURL):
        state.serverURL = serverURL
        return .send(.refresh)

      case .refresh:
        guard let serverURL = state.serverURL else {
          state.error = "Select a server in Settings."
          state.docs = []
          return .none
        }
        state.isLoading = true
        state.error = nil
        return .run { send in
          await send(
            .refreshResponse(
              TaskResult {
                try await wuhuClientProvider.make(serverURL).listWorkspaceDocs()
              },
            ),
          )
        }

      case let .refreshResponse(.success(docs)):
        state.isLoading = false
        state.error = nil
        state.docs = IdentifiedArray(uniqueElements: docs)
        return .none

      case let .refreshResponse(.failure(error)):
        state.isLoading = false
        state.error = "\(error)"
        return .none

      case .clearFilter:
        state.filterKey = nil
        state.filterValue = nil
        return .none

      case let .setFilter(key, value):
        state.filterKey = key
        state.filterValue = value
        return .none

      case .binding:
        return .none
      }
    }
  }

  private func refreshTimerEffect() -> Effect<Action> {
    .run { send in
      for await _ in clock.timer(interval: .seconds(30)) {
        await send(.refresh)
      }
    }
    .cancellable(id: CancelID.refreshTimer, cancelInFlight: true)
  }
}
