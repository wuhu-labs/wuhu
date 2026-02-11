import ComposableArchitecture
import Foundation
import WuhuAPI
import WuhuClient

@Reducer
struct SessionDetailFeature {
  enum Verbosity: String, CaseIterable, Hashable {
    case minimal
    case compact
  }

  @ObservableState
  struct State: Equatable, Identifiable {
    var id: String {
      sessionID
    }

    var sessionID: String
    var serverURL: URL?
    var username: String?

    var session: WuhuSession?
    var transcript: IdentifiedArrayOf<WuhuSessionEntry> = []

    var isLoading = false
    var isSending = false

    var error: String?

    var draft: String = ""
    var streamingAssistantText: String = ""

    var verbosity: Verbosity = .minimal

    init(sessionID: String, serverURL: URL?, username: String?) {
      self.sessionID = sessionID
      self.serverURL = serverURL
      self.username = username
    }
  }

  enum Action: BindableAction {
    case onAppear
    case onDisappear
    case binding(BindingAction<State>)

    case refresh
    case refreshResponse(TaskResult<WuhuGetSessionResponse>)

    case startFollow
    case followEvent(WuhuSessionStreamEvent)
    case followFailed(String)

    case sendTapped
    case promptEvent(WuhuSessionStreamEvent)
    case promptFailed(String)

    case delegate(Delegate)

    enum Delegate: Equatable {
      case didClose
    }
  }

  @Dependency(\.wuhuClientProvider) private var wuhuClientProvider

  private enum CancelID {
    case follow
    case prompt
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Reduce { state, action in
      switch action {
      case .onAppear:
        return .merge(
          .send(.refresh),
          .send(.startFollow),
        )

      case .onDisappear:
        return .merge(
          .cancel(id: CancelID.follow),
          .cancel(id: CancelID.prompt),
          .send(.delegate(.didClose)),
        )

      case .refresh:
        guard let serverURL = state.serverURL else {
          state.error = "No server selected."
          return .none
        }
        state.isLoading = true
        state.error = nil
        let sessionID = state.sessionID
        return .run { send in
          await send(
            .refreshResponse(
              TaskResult {
                try await wuhuClientProvider.make(serverURL).getSession(id: sessionID)
              },
            ),
          )
        }

      case let .refreshResponse(.success(response)):
        state.isLoading = false
        state.session = response.session
        state.transcript = IdentifiedArray(uniqueElements: response.transcript)
        return .none

      case let .refreshResponse(.failure(error)):
        state.isLoading = false
        state.error = "\(error)"
        return .none

      case .startFollow:
        guard let serverURL = state.serverURL else { return .none }
        let sessionID = state.sessionID
        let sinceCursor = state.transcript.last?.id
        return .run { send in
          do {
            let stream = try await wuhuClientProvider
              .make(serverURL)
              .followSessionStream(sessionID: sessionID, sinceCursor: sinceCursor)
            for try await event in stream {
              await send(.followEvent(event))
            }
          } catch {
            await send(.followFailed("\(error)"))
          }
        }
        .cancellable(id: CancelID.follow, cancelInFlight: true)

      case let .followEvent(event):
        applyStreamEvent(event, to: &state)
        return .none

      case let .followFailed(message):
        state.error = message
        return .none

      case .sendTapped:
        guard let serverURL = state.serverURL else { return .none }
        let input = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .none }

        state.draft = ""
        state.isSending = true
        state.error = nil
        state.streamingAssistantText = ""

        let sessionID = state.sessionID
        let user = state.username

        return .merge(
          .cancel(id: CancelID.follow),
          .run { send in
            do {
              let stream = try await wuhuClientProvider
                .make(serverURL)
                .promptStream(sessionID: sessionID, input: input, user: user)
              for try await event in stream {
                await send(.promptEvent(event))
              }
            } catch {
              await send(.promptFailed("\(error)"))
            }
          }
          .cancellable(id: CancelID.prompt, cancelInFlight: true),
        )

      case let .promptEvent(event):
        applyStreamEvent(event, to: &state)
        if case .done = event {
          state.isSending = false
          return .send(.startFollow)
        }
        return .none

      case let .promptFailed(message):
        state.isSending = false
        state.error = message
        return .send(.startFollow)

      case .binding:
        return .none

      case .delegate:
        return .none
      }
    }
  }

  private func applyStreamEvent(_ event: WuhuSessionStreamEvent, to state: inout State) {
    switch event {
    case let .entryAppended(entry):
      state.transcript[id: entry.id] = entry
      state.streamingAssistantText = ""
    case let .assistantTextDelta(delta):
      state.streamingAssistantText += delta
    case .idle:
      break
    case .done:
      break
    }
  }
}
