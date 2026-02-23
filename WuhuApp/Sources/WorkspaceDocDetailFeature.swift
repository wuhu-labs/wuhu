import ComposableArchitecture
import Foundation
import WuhuAPI
import WuhuClient

@Reducer
struct WorkspaceDocDetailFeature {
  @ObservableState
  struct State: Equatable {
    var path: String
    var serverURL: URL

    var isLoading = false
    var error: String?
    var doc: WuhuWorkspaceDoc?

    init(path: String, serverURL: URL) {
      self.path = path
      self.serverURL = serverURL
    }
  }

  enum Action {
    case onAppear
    case refresh
    case refreshResponse(TaskResult<WuhuWorkspaceDoc>)
  }

  @Dependency(\.wuhuClientProvider) private var wuhuClientProvider

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case .onAppear:
        return .send(.refresh)

      case .refresh:
        state.isLoading = true
        state.error = nil
        return .run { [path = state.path, serverURL = state.serverURL] send in
          await send(
            .refreshResponse(
              TaskResult {
                try await wuhuClientProvider.make(serverURL).readWorkspaceDoc(path: path)
              },
            ),
          )
        }

      case let .refreshResponse(.success(doc)):
        state.isLoading = false
        state.error = nil
        state.doc = doc
        return .none

      case let .refreshResponse(.failure(error)):
        state.isLoading = false
        state.error = "\(error)"
        return .none
      }
    }
  }
}
