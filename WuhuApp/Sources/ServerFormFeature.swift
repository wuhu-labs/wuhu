import ComposableArchitecture
import Foundation

@Reducer
struct ServerFormFeature {
  enum Mode: Equatable {
    case add
    case edit
  }

  @ObservableState
  struct State: Equatable {
    var mode: Mode
    var server: ServerConfig
    var error: String?

    init(mode: Mode, server: ServerConfig) {
      self.mode = mode
      self.server = server
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case saveTapped
    case cancelTapped
    case delegate(Delegate)

    enum Delegate: Equatable {
      case saved(ServerConfig)
      case cancelled
    }
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Reduce { state, action in
      switch action {
      case .binding:
        state.error = nil
        return .none

      case .saveTapped:
        guard state.server.name.trimmedNonEmpty != nil else {
          state.error = "Server name is required."
          return .none
        }
        guard state.server.url != nil else {
          state.error = "Server URL must be a valid http(s) URL."
          return .none
        }
        state.server.name = state.server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        state.server.urlString = state.server.urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        state.server.username = state.server.username?.trimmingCharacters(in: .whitespacesAndNewlines).trimmedNonEmpty
        return .send(.delegate(.saved(state.server)))

      case .cancelTapped:
        return .send(.delegate(.cancelled))

      case .delegate:
        return .none
      }
    }
  }
}
