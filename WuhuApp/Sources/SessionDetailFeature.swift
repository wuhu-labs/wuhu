import ComposableArchitecture
import Foundation
import PiAI
import WuhuAPI
import WuhuClient

@Reducer
struct SessionDetailFeature {
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
    var inProcessExecution: WuhuInProcessExecutionInfo?
    var inferredExecution: WuhuSessionExecutionInference = .infer(from: [])

    var isLoading = false
    var isSending = false
    var isStopping = false
    var didPromptDeadLoop = false

    var isShowingModelPicker = false
    var isUpdatingModel = false
    var modelUpdateStatus: String?

    var error: String?

    var draft: String = ""
    var streamingAssistantText: String = ""

    var verbosity: WuhuSessionVerbosity = .minimal

    var provider: WuhuProvider = .openai
    var modelSelection: String = ""
    var customModel: String = ""
    var reasoningEffort: ReasoningEffort?

    @Presents var alert: AlertState<Action.Alert>?

    init(sessionID: String, serverURL: URL?, username: String?) {
      self.sessionID = sessionID
      self.serverURL = serverURL
      self.username = username
    }

    var resolvedModelID: String? {
      switch modelSelection {
      case "":
        nil
      case ModelSelectionUI.customModelSentinel:
        customModel.trimmedNonEmpty
      default:
        modelSelection
      }
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
    case promptResponse(TaskResult<WuhuPromptDetachedResponse>)

    case stopTapped
    case stopResponse(TaskResult<WuhuStopSessionResponse>)

    case applyModelTapped
    case setModelResponse(TaskResult<WuhuSetSessionModelResponse>)

    case alert(PresentationAction<Alert>)
    case delegate(Delegate)

    enum Delegate: Equatable {
      case didClose
    }

    enum Alert: Equatable {
      case stopDeadLoopConfirmed
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
        state.inProcessExecution = response.inProcessExecution
        state.inferredExecution = WuhuSessionExecutionInference.infer(from: response.transcript)
        syncModelSelectionFromSession(response.session, transcript: response.transcript, state: &state)

        if let inProcess = response.inProcessExecution,
           !state.didPromptDeadLoop,
           state.inferredExecution.state == .executing,
           inProcess.activePromptCount == 0
        {
          state.didPromptDeadLoop = true
          state.alert = AlertState {
            TextState("Session looks stuck")
          } actions: {
            ButtonState(role: .destructive, action: .send(.stopDeadLoopConfirmed)) {
              TextState("Stop execution")
            }
            ButtonState(role: .cancel) {
              TextState("Keep")
            }
          } message: {
            TextState("This session appears to be executing based on its transcript, but the server reports no active execution. Stop it by appending an “Execution stopped” entry?")
          }
        }

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

        return .run { send in
          await send(
            .promptResponse(
              TaskResult {
                try await wuhuClientProvider
                  .make(serverURL)
                  .promptDetached(sessionID: sessionID, input: input, user: user)
              },
            ),
          )
        }
        .cancellable(id: CancelID.prompt, cancelInFlight: true)

      case .promptResponse(.success):
        // Follow stream drives transcript updates and completion (idle).
        return .none

      case let .promptResponse(.failure(error)):
        state.isSending = false
        state.error = "\(error)"
        return .none

      case .stopTapped:
        guard let serverURL = state.serverURL else { return .none }
        state.isStopping = true
        state.error = nil
        state.streamingAssistantText = ""
        let sessionID = state.sessionID
        let user = state.username
        return .run { send in
          await send(
            .stopResponse(
              TaskResult {
                try await wuhuClientProvider.make(serverURL).stopSession(sessionID: sessionID, user: user)
              },
            ),
          )
        }

      case let .stopResponse(.success(response)):
        state.isStopping = false
        state.isSending = false
        for entry in response.repairedEntries {
          state.transcript[id: entry.id] = entry
        }
        if let stopEntry = response.stopEntry {
          state.transcript[id: stopEntry.id] = stopEntry
        }
        state.inferredExecution = WuhuSessionExecutionInference.infer(from: Array(state.transcript))
        return .none

      case let .stopResponse(.failure(error)):
        state.isStopping = false
        state.error = "\(error)"
        return .none

      case let .binding(binding):
        if binding.keyPath == \.provider {
          state.modelSelection = ""
          state.customModel = ""
          state.reasoningEffort = nil
        }

        let supportedEfforts = WuhuModelCatalog.supportedReasoningEfforts(provider: state.provider, modelID: state.resolvedModelID)
        if let current = state.reasoningEffort,
           !supportedEfforts.contains(current)
        {
          state.reasoningEffort = nil
        }

        return .none

      case .applyModelTapped:
        guard let serverURL = state.serverURL else { return .none }
        state.isUpdatingModel = true
        state.modelUpdateStatus = nil
        state.error = nil

        let sessionID = state.sessionID
        let provider = state.provider
        let model = state.resolvedModelID
        let effort = state.reasoningEffort

        return .run { send in
          await send(
            .setModelResponse(
              TaskResult {
                try await wuhuClientProvider.make(serverURL).setSessionModel(
                  sessionID: sessionID,
                  provider: provider,
                  model: model,
                  reasoningEffort: effort,
                )
              },
            ),
          )
        }

      case let .setModelResponse(.success(response)):
        state.isUpdatingModel = false
        state.modelUpdateStatus = response.applied ? "Applied." : "Pending (will apply when session is idle)."
        state.session = response.session
        state.provider = response.selection.provider
        setModelSelectionInState(provider: response.selection.provider, model: response.selection.model, transcript: Array(state.transcript), state: &state)
        state.reasoningEffort = response.selection.reasoningEffort
        return .none

      case let .setModelResponse(.failure(error)):
        state.isUpdatingModel = false
        state.error = "\(error)"
        return .none

      case .delegate:
        return .none

      case let .alert(.presented(.stopDeadLoopConfirmed)):
        return .send(.stopTapped)

      case .alert:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert) {
      EmptyReducer()
    }
  }

  private func applyStreamEvent(_ event: WuhuSessionStreamEvent, to state: inout State) {
    switch event {
    case let .entryAppended(entry):
      state.transcript[id: entry.id] = entry
      state.streamingAssistantText = ""
      state.inferredExecution = WuhuSessionExecutionInference.infer(from: Array(state.transcript))
      if case let .sessionSettings(s) = entry.payload {
        state.session?.provider = s.provider
        state.session?.model = s.model
        state.provider = s.provider
        setModelSelectionInState(provider: s.provider, model: s.model, transcript: Array(state.transcript), state: &state)
        state.reasoningEffort = s.reasoningEffort
        state.modelUpdateStatus = nil
      }
    case let .assistantTextDelta(delta):
      state.streamingAssistantText += delta
    case .idle:
      state.isSending = false
      state.isStopping = false
      if state.inProcessExecution != nil {
        state.inProcessExecution = .init(activePromptCount: 0)
      }
    case .done:
      break
    }
  }

  private func syncModelSelectionFromSession(_ session: WuhuSession, transcript: [WuhuSessionEntry], state: inout State) {
    guard !state.isShowingModelPicker else { return }
    guard !state.isUpdatingModel else { return }

    state.provider = session.provider
    setModelSelectionInState(provider: session.provider, model: session.model, transcript: transcript, state: &state)
    state.reasoningEffort = currentReasoningEffort(from: transcript)
  }

  private func setModelSelectionInState(provider: WuhuProvider, model: String, transcript _: [WuhuSessionEntry], state: inout State) {
    let knownIDs = Set(WuhuModelCatalog.models(for: provider).map(\.id))
    if knownIDs.contains(model) {
      state.modelSelection = model
      state.customModel = ""
    } else {
      state.modelSelection = ModelSelectionUI.customModelSentinel
      state.customModel = model
    }
  }

  private func currentReasoningEffort(from transcript: [WuhuSessionEntry]) -> ReasoningEffort? {
    for entry in transcript.reversed() {
      if case let .sessionSettings(s) = entry.payload {
        return s.reasoningEffort
      }
    }
    for entry in transcript {
      guard case let .header(h) = entry.payload else { continue }
      guard let raw = h.metadata.object?["reasoningEffort"]?.stringValue else { return nil }
      return ReasoningEffort(rawValue: raw)
    }
    return nil
  }
}
