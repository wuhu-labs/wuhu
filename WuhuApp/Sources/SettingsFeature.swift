import ComposableArchitecture
import Foundation

@Reducer
struct SettingsFeature {
  @ObservableState
  struct State: Equatable {
    var servers: IdentifiedArrayOf<ServerConfig> = []
    var selectedServerID: ServerConfig.ID?
    var username: String = ""

    @Presents var serverForm: ServerFormFeature.State?
  }

  enum Action: BindableAction {
    case onAppear
    case binding(BindingAction<State>)

    case addServerButtonTapped
    case editServerButtonTapped(ServerConfig.ID)
    case deleteServers(IndexSet)
    case selectServer(ServerConfig.ID)

    case serverForm(PresentationAction<ServerFormFeature.Action>)

    case delegate(Delegate)

    enum Delegate: Equatable {
      case settingsChanged(AppSettings)
    }
  }

  @Dependency(\.appSettingsClient) private var appSettings

  var body: some ReducerOf<Self> {
    BindingReducer()

    Reduce { state, action in
      switch action {
      case .onAppear:
        let settings = appSettings.load()
        state.servers = IdentifiedArray(uniqueElements: settings.servers)
        state.selectedServerID = settings.selectedServerID ?? state.servers.first?.id
        state.username = settings.username
        return .send(.delegate(.settingsChanged(currentSettings(from: state))))

      case .binding:
        return persistAndDelegate(state: state)

      case .addServerButtonTapped:
        state.serverForm = .init(mode: .add, server: .init(name: "", urlString: ""))
        return .none

      case let .editServerButtonTapped(id):
        guard let server = state.servers[id: id] else { return .none }
        state.serverForm = .init(mode: .edit, server: server)
        return .none

      case let .deleteServers(offsets):
        state.servers.remove(atOffsets: offsets)
        if let selected = state.selectedServerID, state.servers[id: selected] == nil {
          state.selectedServerID = state.servers.first?.id
        }
        return persistAndDelegate(state: state)

      case let .selectServer(id):
        state.selectedServerID = id
        return persistAndDelegate(state: state)

      case let .serverForm(.presented(.delegate(.saved(server)))):
        switch state.serverForm?.mode {
        case .add:
          state.servers.append(server)
          state.selectedServerID = state.selectedServerID ?? server.id
        case .edit:
          state.servers[id: server.id] = server
        case .none:
          break
        }
        state.serverForm = nil
        return persistAndDelegate(state: state)

      case .serverForm(.presented(.delegate(.cancelled))):
        state.serverForm = nil
        return .none

      case .serverForm:
        return .none

      case .delegate:
        return .none
      }
    }
    .ifLet(\.$serverForm, action: \.serverForm) {
      ServerFormFeature()
    }
  }

  private func currentSettings(from state: State) -> AppSettings {
    .init(servers: Array(state.servers), selectedServerID: state.selectedServerID, username: state.username)
  }

  private func persistAndDelegate(state: State) -> Effect<Action> {
    let settings = currentSettings(from: state)
    return .run { send in
      appSettings.save(settings)
      await send(.delegate(.settingsChanged(settings)))
    }
  }
}
