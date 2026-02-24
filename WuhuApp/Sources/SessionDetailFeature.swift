import ComposableArchitecture
import Foundation
import PiAI
import WuhuAPI
import WuhuClient
import WuhuCore

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

    var transcript: IdentifiedArrayOf<WuhuSessionEntry> = []
    var skills: [WuhuSkill] = []

    var sessionType: WuhuSessionType = .coding
    var displayStartEntryID: Int64?

    var settings: SessionSettingsSnapshot?
    var status: SessionStatusSnapshot?

    var systemUrgent: SystemUrgentQueueBackfill?
    var steer: UserQueueBackfill?
    var followUp: UserQueueBackfill?

    var isSubscribing = false
    var isRetrying = false
    var retryAttempt = 0
    var retryDelaySeconds: Double = 0

    var isEnqueuing = false
    var isStopping = false

    var isShowingModelPicker = false
    var isShowingSkills = false
    var isUpdatingModel = false
    var modelUpdateStatus: String?

    var error: String?

    var draft: String = ""

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

    var executionStatus: SessionExecutionStatus {
      status?.status ?? .idle
    }
  }

  enum Action: BindableAction {
    case onAppear
    case onDisappear
    case binding(BindingAction<State>)

    case loadSessionInfo
    case loadSessionInfoResponse(TaskResult<WuhuGetSessionResponse>)

    case startSubscription
    case subscriptionInitial(SessionInitialState)
    case subscriptionEvent(SessionEvent)
    case connectionStateChanged(SSEConnectionState)
    case subscriptionFailed(String)

    case sendTapped
    case enqueueResponse(TaskResult<QueueItemID>)

    case stopTapped
    case stopResponse(TaskResult<WuhuStopSessionResponse>)

    case applyModelTapped
    case setModelResponse(TaskResult<WuhuSetSessionModelResponse>)

    case alert(PresentationAction<Alert>)
    case delegate(Delegate)

    enum Delegate: Equatable {
      case didClose
    }

    enum Alert: Equatable {}
  }

  @Dependency(\.wuhuClientProvider) private var wuhuClientProvider
  @Dependency(\.sessionTransportProvider) private var sessionTransportProvider

  private enum CancelID {
    case subscription
    case enqueue
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Reduce { state, action in
      switch action {
      case .onAppear:
        state.error = nil
        return .merge(
          .send(.loadSessionInfo),
          .send(.startSubscription),
        )

      case .onDisappear:
        return .merge(
          .cancel(id: CancelID.subscription),
          .cancel(id: CancelID.enqueue),
          .send(.delegate(.didClose)),
        )

      case .loadSessionInfo:
        guard let serverURL = state.serverURL else { return .none }
        let sessionID = state.sessionID
        return .run { send in
          await send(
            .loadSessionInfoResponse(
              TaskResult {
                try await wuhuClientProvider.make(serverURL).getSession(id: sessionID)
              },
            ),
          )
        }

      case let .loadSessionInfoResponse(.success(response)):
        state.sessionType = response.session.type
        state.displayStartEntryID = response.session.displayStartEntryID
        if let start = state.displayStartEntryID {
          state.transcript = IdentifiedArray(uniqueElements: state.transcript.filter { $0.id >= start })
          state.skills = WuhuSkills.extract(from: Array(state.transcript))
        }
        return .none

      case let .loadSessionInfoResponse(.failure(error)):
        // Best-effort: subscription still works without this.
        state.error = state.error ?? "\(error)"
        return .none

      case .startSubscription:
        guard let serverURL = state.serverURL else {
          state.error = "No server selected."
          return .none
        }

        state.isSubscribing = true
        state.isRetrying = false
        state.retryAttempt = 0
        state.retryDelaySeconds = 0
        state.error = nil

        let sessionID = state.sessionID
        let since = makeSinceRequest(from: state)
        let transport = sessionTransportProvider.make(serverURL)

        return .run { send in
          do {
            let result = try await transport.subscribeWithConnectionState(sessionID: .init(rawValue: sessionID), since: since)
            await send(.subscriptionInitial(result.subscription.initial))

            await withTaskGroup(of: Void.self) { group in
              group.addTask {
                for await connection in result.connectionStates {
                  await send(.connectionStateChanged(connection))
                }
              }

              group.addTask {
                do {
                  for try await event in result.subscription.events {
                    await send(.subscriptionEvent(event))
                  }
                } catch {
                  if Task.isCancelled { return }
                  await send(.subscriptionFailed("\(error)"))
                }
              }

              await group.waitForAll()
            }
          } catch {
            if Task.isCancelled { return }
            await send(.subscriptionFailed("\(error)"))
          }
        }
        .cancellable(id: CancelID.subscription, cancelInFlight: true)

      case let .subscriptionInitial(initial):
        state.isSubscribing = false

        state.settings = initial.settings
        state.status = initial.status
        state.systemUrgent = initial.systemUrgent
        state.steer = initial.steer
        state.followUp = initial.followUp

        let filtered: [WuhuSessionEntry] = if let start = state.displayStartEntryID {
          initial.transcript.filter { $0.id >= start }
        } else {
          initial.transcript
        }
        state.transcript = IdentifiedArray(uniqueElements: filtered)
        state.skills = WuhuSkills.extract(from: filtered)

        syncModelSelectionFromSettings(initial.settings, state: &state)

        return .none

      case let .connectionStateChanged(connection):
        switch connection {
        case .connecting:
          state.isSubscribing = true
          state.isRetrying = false
          state.retryAttempt = 0
          state.retryDelaySeconds = 0

        case .connected:
          state.isSubscribing = false
          state.isRetrying = false
          state.retryAttempt = 0
          state.retryDelaySeconds = 0

        case let .retrying(attempt, delaySeconds):
          state.isSubscribing = false
          state.isRetrying = true
          state.retryAttempt = attempt
          state.retryDelaySeconds = delaySeconds

        case .closed:
          state.isSubscribing = false
          state.isRetrying = false
        }
        return .none

      case let .subscriptionEvent(event):
        state.error = nil
        apply(event: event, to: &state)
        if case .transcriptAppended = event {
          state.skills = WuhuSkills.extract(from: Array(state.transcript))
        }
        return .none

      case let .subscriptionFailed(message):
        state.isSubscribing = false
        state.isRetrying = false
        state.error = message
        return .none

      case .sendTapped:
        guard let serverURL = state.serverURL else { return .none }
        let input = state.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .none }

        state.draft = ""
        state.isEnqueuing = true
        state.error = nil

        let sessionID = state.sessionID
        let author: Author = {
          let trimmed = (state.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmed.isEmpty { return .unknown }
          return .participant(.init(rawValue: trimmed), kind: .human)
        }()

        let message = QueuedUserMessage(author: author, content: .text(input))
        let transport = sessionTransportProvider.make(serverURL)

        return .run { send in
          await send(
            .enqueueResponse(
              TaskResult {
                try await transport.enqueue(sessionID: .init(rawValue: sessionID), message: message, lane: .followUp)
              },
            ),
          )
        }
        .cancellable(id: CancelID.enqueue, cancelInFlight: true)

      case .enqueueResponse(.success):
        state.isEnqueuing = false
        return .none

      case let .enqueueResponse(.failure(error)):
        state.isEnqueuing = false
        state.error = "\(error)"
        return .none

      case .stopTapped:
        guard let serverURL = state.serverURL else { return .none }
        state.isStopping = true
        state.error = nil

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

      case .stopResponse(.success):
        state.isStopping = false
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

        let supportedEfforts = WuhuModelCatalog.supportedReasoningEfforts(
          provider: state.provider,
          modelID: state.resolvedModelID,
        )
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
        return .none

      case let .setModelResponse(.failure(error)):
        state.isUpdatingModel = false
        state.error = "\(error)"
        return .none

      case .delegate:
        return .none

      case .alert:
        return .none
      }
    }
    .ifLet(\.$alert, action: \.alert) {
      EmptyReducer()
    }
  }

  private func makeSinceRequest(from state: State) -> SessionSubscriptionRequest {
    let transcriptSince = state.transcript.last.map { TranscriptCursor(rawValue: String($0.id)) }

    return SessionSubscriptionRequest(
      transcriptSince: transcriptSince,
      transcriptPageSize: 200,
      systemSince: state.systemUrgent?.cursor,
      steerSince: state.steer?.cursor,
      followUpSince: state.followUp?.cursor,
    )
  }

  private func apply(event: SessionEvent, to state: inout State) {
    switch event {
    case let .transcriptAppended(entries):
      let filtered: [WuhuSessionEntry] = if let start = state.displayStartEntryID {
        entries.filter { $0.id >= start }
      } else {
        entries
      }
      for entry in filtered {
        state.transcript[id: entry.id] = entry
      }

    case let .systemUrgentQueue(cursor, entries: entries):
      if var backfill = state.systemUrgent {
        backfill.cursor = cursor
        backfill.journal.append(contentsOf: entries)
        state.systemUrgent = backfill
      }

    case let .userQueue(cursor, entries):
      guard let lane = entries.first?.lane else { break }
      switch lane {
      case .steer:
        if var backfill = state.steer {
          backfill.cursor = cursor
          backfill.journal.append(contentsOf: entries)
          state.steer = backfill
        }
      case .followUp:
        if var backfill = state.followUp {
          backfill.cursor = cursor
          backfill.journal.append(contentsOf: entries)
          state.followUp = backfill
        }
      }

    case let .settingsUpdated(settings):
      state.settings = settings
      syncModelSelectionFromSettings(settings, state: &state)
      state.modelUpdateStatus = nil

    case let .statusUpdated(status):
      state.status = status
      if status.status == .idle {
        state.isStopping = false
      }
    }
  }

  private func syncModelSelectionFromSettings(_ settings: SessionSettingsSnapshot, state: inout State) {
    guard !state.isShowingModelPicker else { return }
    guard !state.isUpdatingModel else { return }

    state.provider = wuhuProviderFromSettings(settings)
    setModelSelectionInState(provider: state.provider, model: settings.effectiveModel.id, state: &state)
    state.reasoningEffort = settings.effectiveReasoningEffort
  }

  private func wuhuProviderFromSettings(_ settings: SessionSettingsSnapshot) -> WuhuProvider {
    switch settings.effectiveModel.provider {
    case .openai:
      .openai
    case .openaiCodex:
      .openaiCodex
    case .anthropic:
      .anthropic
    default:
      .openai
    }
  }

  private func setModelSelectionInState(provider: WuhuProvider, model: String, state: inout State) {
    let knownIDs = Set(WuhuModelCatalog.models(for: provider).map(\.id))
    if knownIDs.contains(model) {
      state.modelSelection = model
      state.customModel = ""
    } else {
      state.modelSelection = ModelSelectionUI.customModelSentinel
      state.customModel = model
    }
  }
}
