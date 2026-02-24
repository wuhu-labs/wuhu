import ComposableArchitecture
import SwiftUI
import WuhuAPI

@Reducer
struct CreateChannelFeature {
  @ObservableState
  struct State: Equatable {
    var sessionType: WuhuSessionType = .channel
    var environments: [WuhuEnvironmentDefinition] = []
    var selectedEnvironment: String = ""
    var isLoading = false
    var isCreating = false
    var error: String?
  }

  enum Action {
    case onAppear
    case environmentsLoaded([WuhuEnvironmentDefinition])
    case loadFailed(String)
    case selectedEnvironmentChanged(String)
    case createTapped
    case createResponse(WuhuSession)
    case createFailed(String)
    case cancelTapped
    case delegate(Delegate)

    enum Delegate: Equatable {
      case created(WuhuSession)
      case cancelled
    }
  }

  @Dependency(\.apiClient) var apiClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        state.isLoading = true
        return .run { send in
          let envs = try await apiClient.listEnvironments()
          await send(.environmentsLoaded(envs))
        } catch: { error, send in
          await send(.loadFailed("\(error)"))
        }

      case let .environmentsLoaded(envs):
        state.isLoading = false
        state.environments = envs
        if state.selectedEnvironment.isEmpty, let first = envs.first {
          state.selectedEnvironment = first.name
        }
        return .none

      case let .loadFailed(message):
        state.isLoading = false
        state.error = message
        return .none

      case let .selectedEnvironmentChanged(name):
        state.selectedEnvironment = name
        return .none

      case .createTapped:
        guard !state.selectedEnvironment.isEmpty else {
          state.error = "Select an environment."
          return .none
        }
        state.isCreating = true
        state.error = nil
        let env = state.selectedEnvironment
        let sessionType = state.sessionType
        return .run { send in
          let session = try await apiClient.createSession(
            WuhuCreateSessionRequest(type: sessionType, provider: .anthropic, environment: env)
          )
          await send(.createResponse(session))
        } catch: { error, send in
          await send(.createFailed("\(error)"))
        }

      case let .createResponse(session):
        state.isCreating = false
        return .send(.delegate(.created(session)))

      case let .createFailed(message):
        state.isCreating = false
        state.error = message
        return .none

      case .cancelTapped:
        return .send(.delegate(.cancelled))

      case .delegate:
        return .none
      }
    }
  }
}

// MARK: - View

struct CreateChannelView: View {
  @Bindable var store: StoreOf<CreateChannelFeature>

  var body: some View {
    NavigationStack {
      Form {
        if store.isLoading {
          Section {
            ProgressView("Loading environments...")
          }
        } else if store.environments.isEmpty {
          Section {
            Text("No environments available.")
              .foregroundStyle(.secondary)
          }
        } else {
          Section("Environment") {
            Picker("Environment", selection: $store.selectedEnvironment.sending(\.selectedEnvironmentChanged)) {
              ForEach(store.environments, id: \.name) { env in
                Text(env.name).tag(env.name)
              }
            }
            .labelsHidden()
          }
        }

        if let error = store.error {
          Section {
            Text(error)
              .foregroundStyle(.red)
              .font(.caption)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(store.sessionType == .channel ? "New Channel" : "New Session")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            store.send(.cancelTapped)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Create") {
            store.send(.createTapped)
          }
          .disabled(store.selectedEnvironment.isEmpty || store.isCreating)
        }
      }
    }
    .frame(minWidth: 350, minHeight: 200)
    .task { store.send(.onAppear) }
  }
}
