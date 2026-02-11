import ComposableArchitecture
import Foundation
import WuhuAPI
import WuhuClient

@Reducer
struct CreateSessionFeature {
  @ObservableState
  struct State: Equatable {
    var serverURL: URL
    var username: String?

    var environments: [WuhuEnvironmentInfo] = []
    var runners: [WuhuRunnerInfo] = []
    var isLoadingOptions = false

    var provider: WuhuProvider = .openai
    var environmentName: String = ""
    var runnerName: String = ""
    var model: String = ""
    var systemPrompt: String = ""

    var isCreating = false
    var error: String?

    init(serverURL: URL, username: String?) {
      self.serverURL = serverURL
      self.username = username
    }
  }

  enum Action: BindableAction {
    case onAppear
    case binding(BindingAction<State>)

    case loadOptionsResponse(TaskResult<(envs: [WuhuEnvironmentInfo], runners: [WuhuRunnerInfo])>)
    case createTapped
    case createResponse(TaskResult<WuhuSession>)
    case cancelTapped

    case delegate(Delegate)

    enum Delegate: Equatable {
      case created(WuhuSession)
      case cancelled
    }
  }

  @Dependency(\.wuhuClientProvider) private var wuhuClientProvider

  var body: some ReducerOf<Self> {
    BindingReducer()

    Reduce { state, action in
      switch action {
      case .onAppear:
        state.isLoadingOptions = true
        state.error = nil
        let serverURL = state.serverURL
        return .run { send in
          await send(
            .loadOptionsResponse(
              TaskResult {
                async let envs = wuhuClientProvider.make(serverURL).listEnvironments()
                async let runners = wuhuClientProvider.make(serverURL).listRunners()
                return try await (envs: envs, runners: runners)
              },
            ),
          )
        }

      case let .loadOptionsResponse(.success(options)):
        state.isLoadingOptions = false
        state.environments = options.envs
        state.runners = options.runners
        if state.environmentName.isEmpty {
          state.environmentName = options.envs.first?.name ?? ""
        }
        return .none

      case let .loadOptionsResponse(.failure(error)):
        state.isLoadingOptions = false
        state.error = "\(error)"
        return .none

      case .createTapped:
        guard !state.environmentName.isEmpty else {
          state.error = "Select an environment."
          return .none
        }
        state.isCreating = true
        state.error = nil

        let serverURL = state.serverURL
        let request = WuhuCreateSessionRequest(
          provider: state.provider,
          model: state.model.trimmedNonEmpty,
          systemPrompt: state.systemPrompt.trimmedNonEmpty,
          environment: state.environmentName,
          runner: state.runnerName.trimmedNonEmpty,
        )
        return .run { send in
          await send(
            .createResponse(
              TaskResult {
                try await wuhuClientProvider.make(serverURL).createSession(request)
              },
            ),
          )
        }

      case let .createResponse(.success(session)):
        state.isCreating = false
        return .send(.delegate(.created(session)))

      case let .createResponse(.failure(error)):
        state.isCreating = false
        state.error = "\(error)"
        return .none

      case .cancelTapped:
        return .send(.delegate(.cancelled))

      case .binding:
        state.error = nil
        return .none

      case .delegate:
        return .none
      }
    }
  }
}
