import ComposableArchitecture
import IdentifiedCollections
import MarkdownUI
import PiAI
import SwiftUI
import WuhuAPI
import WuhuCore

@Reducer
struct SessionFeature {
  @ObservableState
  struct State {
    var sessions: IdentifiedArrayOf<MockSession> = []
    var selectedSessionID: String?
    var isLoadingDetail = false

    // Subscription state for the selected session
    var transcript: IdentifiedArrayOf<WuhuSessionEntry> = []
    var displayStartEntryID: Int64?
    var settings: SessionSettingsSnapshot?
    var status: SessionStatusSnapshot?
    var systemUrgent: SystemUrgentQueueBackfill?
    var steer: UserQueueBackfill?
    var followUp: UserQueueBackfill?

    // Rename state
    var isShowingRenameDialog = false
    var renameSessionID: String?
    var renameText: String = ""

    // Model picker state
    var provider: WuhuProvider = .anthropic
    var modelSelection: String = ""
    var customModel: String = ""
    var reasoningEffort: ReasoningEffort?
    var isShowingModelPicker = false
    var isUpdatingModel = false
    var modelUpdateStatus: String?

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

    // Connection state
    var isSubscribing = false
    var isRetrying = false
    var retryAttempt = 0
    var retryDelaySeconds: Double = 0
    var subscriptionError: String?

    var selectedSession: MockSession? {
      guard let id = selectedSessionID else { return nil }
      return sessions[id: id]
    }

    var executionStatus: SessionExecutionStatus {
      status?.status ?? .idle
    }
  }

  enum Action: BindableAction {
    case binding(BindingAction<State>)
    case sessionSelected(String?)
    case sessionInfoLoaded(WuhuGetSessionResponse)
    case sessionInfoFailed

    // Subscription lifecycle
    case startSubscription
    case subscriptionInitial(SessionInitialState)
    case subscriptionEvent(SessionEvent)
    case connectionStateChanged(SSEConnectionState)
    case subscriptionFailed(String)

    // Rename
    case renameMenuTapped(String)
    case renameConfirmed
    case renameCancelled
    case renameResponse(Result<WuhuRenameSessionResponse, any Error>)

    // Commands
    case sendMessage(String)
    case enqueueSucceeded
    case enqueueFailed(String)

    // Model switching
    case applyModelTapped
    case setModelResponse(Result<WuhuSetSessionModelResponse, any Error>)
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.sessionTransportProvider) var sessionTransportProvider

  private enum CancelID {
    case subscription
  }

  var body: some ReducerOf<Self> {
    BindingReducer()

    Reduce { state, action in
      switch action {
      case let .binding(binding):
        if binding.keyPath == \State.provider {
          state.modelSelection = ""
          state.customModel = ""
          state.reasoningEffort = nil
        }
        let supportedEfforts = WuhuModelCatalog.supportedReasoningEfforts(
          provider: state.provider, modelID: state.resolvedModelID,
        )
        if let current = state.reasoningEffort, !supportedEfforts.contains(current) {
          state.reasoningEffort = nil
        }
        return .none

      case let .sessionSelected(id):
        let previousID = state.selectedSessionID
        state.selectedSessionID = id
        state.subscriptionError = nil

        // Clear subscription state when deselecting or switching
        if id != previousID {
          state.transcript = []
          state.displayStartEntryID = nil
          state.settings = nil
          state.status = nil
          state.systemUrgent = nil
          state.steer = nil
          state.followUp = nil
          state.isSubscribing = false
          state.isRetrying = false
        }

        guard let id else {
          state.isLoadingDetail = false
          return .cancel(id: CancelID.subscription)
        }

        state.isLoadingDetail = true
        return .merge(
          .cancel(id: CancelID.subscription),
          .run { send in
            let response = try await apiClient.getSession(id)
            await send(.sessionInfoLoaded(response))
          } catch: { _, send in
            await send(.sessionInfoFailed)
          },
        )

      case let .sessionInfoLoaded(response):
        state.isLoadingDetail = false
        state.displayStartEntryID = response.session.displayStartEntryID

        // Update session in the list with messages from the REST response
        // (subscription will take over after this)
        let session = MockSession.from(response)
        state.sessions[id: session.id] = session

        return .send(.startSubscription)

      case .sessionInfoFailed:
        state.isLoadingDetail = false
        state.subscriptionError = "Failed to load session."
        return .none

      // MARK: - Subscription

      case .startSubscription:
        guard let sessionID = state.selectedSessionID else { return .none }

        state.isSubscribing = true
        state.isRetrying = false
        state.retryAttempt = 0
        state.retryDelaySeconds = 0
        state.subscriptionError = nil

        let since = makeSinceRequest(from: state)
        let transport = sessionTransportProvider.make()

        return .run { send in
          let result = try await transport.subscribeWithConnectionState(
            sessionID: .init(rawValue: sessionID),
            since: since,
          )
          await send(.subscriptionInitial(result.subscription.initial))

          await withTaskGroup(of: Void.self) { group in
            group.addTask {
              for await connectionState in result.connectionStates {
                await send(.connectionStateChanged(connectionState))
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
        } catch: { error, send in
          if Task.isCancelled { return }
          await send(.subscriptionFailed("\(error)"))
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

        // Derive messages and update selected session
        updateSelectedSessionMessages(state: &state)

        // Update status from subscription
        if let status = state.status {
          updateSelectedSessionStatus(status, state: &state)
        }

        // Sync model picker from server settings
        syncModelSelectionFromSettings(initial.settings, state: &state)

        return .none

      case let .subscriptionEvent(event):
        state.subscriptionError = nil
        applyEvent(event, to: &state)

        if case .transcriptAppended = event {
          updateSelectedSessionMessages(state: &state)
        }
        if case let .statusUpdated(status) = event {
          updateSelectedSessionStatus(status, state: &state)
        }
        if case let .settingsUpdated(settings) = event {
          syncModelSelectionFromSettings(settings, state: &state)
          state.modelUpdateStatus = nil
        }

        return .none

      case let .connectionStateChanged(connectionState):
        switch connectionState {
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

      case let .subscriptionFailed(message):
        state.isSubscribing = false
        state.isRetrying = false
        state.subscriptionError = message
        return .none

      // MARK: - Rename

      case let .renameMenuTapped(sessionID):
        state.renameSessionID = sessionID
        state.renameText = state.sessions[id: sessionID]?.title ?? ""
        state.isShowingRenameDialog = true
        return .none

      case .renameConfirmed:
        guard let sessionID = state.renameSessionID else { return .none }
        let newTitle = state.renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.isShowingRenameDialog = false
        state.renameSessionID = nil

        guard !newTitle.isEmpty else { return .none }

        // Optimistically update
        state.sessions[id: sessionID]?.title = newTitle
        state.sessions[id: sessionID]?.customTitle = newTitle

        return .run { send in
          await send(
            .renameResponse(
              Result { try await apiClient.renameSession(sessionID, newTitle) },
            ),
          )
        }

      case .renameCancelled:
        state.isShowingRenameDialog = false
        state.renameSessionID = nil
        state.renameText = ""
        return .none

      case let .renameResponse(.success(response)):
        // Sync server's canonical title back
        let sessionID = response.session.id
        if let customTitle = response.session.customTitle {
          state.sessions[id: sessionID]?.title = customTitle
        }
        return .none

      case let .renameResponse(.failure(error)):
        state.subscriptionError = "Rename failed: \(error)"
        return .none

      // MARK: - Commands

      case let .sendMessage(content):
        guard let sessionID = state.selectedSessionID else { return .none }

        // Optimistically add user message to the UI
        let username = UserDefaults.standard.string(forKey: "wuhuUsername")
        let trimmedUser = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        state.sessions[id: sessionID]?.messages.append(MockMessage(
          role: .user,
          author: trimmedUser.isEmpty ? nil : trimmedUser,
          content: content,
          timestamp: Date(),
        ))

        return .run { send in
          let user: String? = {
            let v = UserDefaults.standard.string(forKey: "wuhuUsername") ?? ""
            return v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : v
          }()
          _ = try await apiClient.enqueue(sessionID, content, user)
          await send(.enqueueSucceeded)
        } catch: { error, send in
          await send(.enqueueFailed("\(error)"))
        }

      case .enqueueSucceeded:
        // The subscription will pick up the response via events
        return .none

      case let .enqueueFailed(message):
        state.subscriptionError = message
        return .none

      // MARK: - Model Switching

      case .applyModelTapped:
        guard let sessionID = state.selectedSessionID else { return .none }
        state.isUpdatingModel = true
        state.modelUpdateStatus = nil

        let provider = state.provider
        let model = state.resolvedModelID
        let effort = state.reasoningEffort

        return .run { send in
          await send(
            .setModelResponse(
              Result {
                try await apiClient.setSessionModel(sessionID, provider, model, effort)
              },
            ),
          )
        }

      case let .setModelResponse(.success(response)):
        state.isUpdatingModel = false
        state.modelUpdateStatus = response.applied
          ? "Applied."
          : "Pending (will apply when session is idle)."
        return .none

      case let .setModelResponse(.failure(error)):
        state.isUpdatingModel = false
        state.subscriptionError = "\(error)"
        return .none
      }
    }
  }

  // MARK: - Helpers

  private func makeSinceRequest(from state: State) -> SessionSubscriptionRequest {
    let transcriptSince = state.transcript.last.map {
      TranscriptCursor(rawValue: String($0.id))
    }
    return SessionSubscriptionRequest(
      transcriptSince: transcriptSince,
      transcriptPageSize: 200,
      systemSince: state.systemUrgent?.cursor,
      steerSince: state.steer?.cursor,
      followUpSince: state.followUp?.cursor,
    )
  }

  private func applyEvent(_ event: SessionEvent, to state: inout State) {
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

    case let .systemUrgentQueue(cursor, entries):
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

    case let .statusUpdated(status):
      state.status = status

    case .streamBegan, .streamDelta, .streamEnded:
      break
    }
  }

  private func updateSelectedSessionMessages(state: inout State) {
    guard let sessionID = state.selectedSessionID else { return }
    let messages = TranscriptConverter.convertTranscript(
      Array(state.transcript),
      displayStartEntryID: state.displayStartEntryID,
    )
    state.sessions[id: sessionID]?.messages = messages

    // Update title from transcript only when there is no user-supplied custom title
    if state.sessions[id: sessionID]?.customTitle == nil,
       let title = TranscriptConverter.deriveSessionTitle(from: Array(state.transcript))
    {
      state.sessions[id: sessionID]?.title = title
    }
  }

  private func syncModelSelectionFromSettings(_ settings: SessionSettingsSnapshot, state: inout State) {
    guard !state.isShowingModelPicker else { return }
    guard !state.isUpdatingModel else { return }

    state.provider = wuhuProviderFromSettings(settings)
    let model = settings.effectiveModel.id
    let knownIDs = Set(WuhuModelCatalog.models(for: state.provider).map(\.id))
    if knownIDs.contains(model) {
      state.modelSelection = model
      state.customModel = ""
    } else {
      state.modelSelection = ModelSelectionUI.customModelSentinel
      state.customModel = model
    }
    state.reasoningEffort = settings.effectiveReasoningEffort

    // Update session model display
    if let sessionID = state.selectedSessionID {
      state.sessions[id: sessionID]?.model = model
    }
  }

  private func wuhuProviderFromSettings(_ settings: SessionSettingsSnapshot) -> WuhuProvider {
    switch settings.effectiveModel.provider {
    case .openai: .openai
    case .openaiCodex: .openaiCodex
    case .anthropic: .anthropic
    default: .openai
    }
  }

  private func updateSelectedSessionStatus(_ status: SessionStatusSnapshot, state: inout State) {
    guard let sessionID = state.selectedSessionID else { return }
    let mockStatus: MockSession.SessionStatus = switch status.status {
    case .running: .running
    case .idle: .idle
    case .stopped: .stopped
    }
    state.sessions[id: sessionID]?.status = mockStatus
  }
}

// MARK: - Session List (content column)

struct SessionListView: View {
  @Bindable var store: StoreOf<SessionFeature>

  var body: some View {
    List(selection: $store.selectedSessionID.sending(\.sessionSelected)) {
      ForEach(store.sessions) { session in
        SessionRow(session: session)
          .tag(session.id)
          .contextMenu {
            Button("Rename…") {
              store.send(.renameMenuTapped(session.id))
            }
          }
      }
    }
    .listStyle(.inset)
    .navigationTitle("Sessions")
    .alert("Rename Session", isPresented: $store.isShowingRenameDialog) {
      TextField("Session title", text: $store.renameText)
      Button("Rename") {
        store.send(.renameConfirmed)
      }
      Button("Cancel", role: .cancel) {
        store.send(.renameCancelled)
      }
    } message: {
      Text("Enter a new title for this session.")
    }
  }
}

// MARK: - Session Detail (detail column)

struct SessionDetailView: View {
  @Bindable var store: StoreOf<SessionFeature>

  var body: some View {
    Group {
      if store.isLoadingDetail {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let session = store.selectedSession {
        SessionThreadView(
          session: session,
          isRunning: store.executionStatus == .running,
          isRetrying: store.isRetrying,
          retryAttempt: store.retryAttempt,
          retryDelaySeconds: store.retryDelaySeconds,
          onSend: { message in
            store.send(.sendMessage(message))
          },
        )
      } else {
        ContentUnavailableView(
          "No Session Selected",
          systemImage: "terminal",
          description: Text("Select a session to view its thread"),
        )
      }
    }
    .toolbar {
      if store.selectedSession != nil {
        ToolbarItemGroup(placement: .primaryAction) {
          Button("Model") {
            store.isShowingModelPicker = true
          }
        }
      }
    }
    .sheet(isPresented: $store.isShowingModelPicker) {
      SessionModelPickerSheet(store: store)
    }
  }
}

// MARK: - Model Picker Sheet

private struct SessionModelPickerSheet: View {
  @Bindable var store: StoreOf<SessionFeature>

  var body: some View {
    NavigationStack {
      Form {
        if let status = store.modelUpdateStatus {
          Section {
            Text(status)
              .foregroundStyle(.secondary)
          }
        }

        if let error = store.subscriptionError {
          Section {
            Text(error)
              .foregroundStyle(.red)
          }
        }

        Section("Model") {
          ModelSelectionFields(
            provider: $store.provider,
            modelSelection: $store.modelSelection,
            customModel: $store.customModel,
            reasoningEffort: $store.reasoningEffort,
          )
        }

        Section {
          Button("Apply") { store.send(.applyModelTapped) }
            .disabled(store.isUpdatingModel)
        }
      }
      .formStyle(.grouped)
      .navigationTitle("Model")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            store.isShowingModelPicker = false
          }
        }
        if store.isUpdatingModel {
          ToolbarItem(placement: .confirmationAction) {
            ProgressView()
          }
        }
      }
    }
    .frame(minWidth: 350, minHeight: 300)
  }
}

// MARK: - Session Row

struct SessionRow: View {
  let session: MockSession

  var body: some View {
    HStack(spacing: 8) {
      Circle()
        .fill(statusColor)
        .frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 3) {
        HStack {
          Text(session.title)
            .font(.callout)
            .fontWeight(.semibold)
            .lineLimit(1)
          Spacer()
          Text(session.updatedAt, style: .relative)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Text(session.lastMessagePreview)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 4)
  }

  private var statusColor: Color {
    switch session.status {
    case .running: .green
    case .idle: .gray
    case .stopped: .red
    }
  }
}

// MARK: - Session Thread View

struct SessionThreadView: View {
  let session: MockSession
  var isRunning: Bool = false
  var isRetrying: Bool = false
  var retryAttempt: Int = 0
  var retryDelaySeconds: Double = 0
  var onSend: ((String) -> Void)?
  @State private var draft = ""

  var body: some View {
    VStack(spacing: 0) {
      // Status bar — full width
      HStack(spacing: 12) {
        Circle().fill(statusColor).frame(width: 8, height: 8)
        Text(session.title).font(.headline)
        Spacer()
        if isRetrying {
          HStack(spacing: 4) {
            Image(systemName: "arrow.clockwise")
              .font(.caption2)
            Text("Retrying (\(String(format: "%.0f", retryDelaySeconds))s)")
              .font(.caption)
          }
          .foregroundStyle(.orange)
        }
        Text(session.environmentName)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(session.model)
          .font(.caption)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(.orange.opacity(0.12))
          .foregroundStyle(.orange)
          .clipShape(Capsule())
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 10)
      .background(.bar)

      Divider()

      // Centered content column
      VStack(spacing: 0) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(session.messages) { message in
              SessionMessageView(message: message)
            }
            if isRunning {
              agentThinkingView
            }
          }
          .padding(16)
        }

        Divider()

        HStack(alignment: .bottom, spacing: 8) {
          TextField("Message...", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1 ... 5)
            .padding(10)
            .background(.background.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onSubmit {
              sendDraft()
            }
          Button {
            sendDraft()
          } label: {
            Image(systemName: "arrow.up.circle.fill")
              .font(.title2)
              .foregroundStyle(draft.isEmpty ? .gray : .orange)
          }
          .buttonStyle(.plain)
          .disabled(draft.isEmpty)
        }
        .padding(12)
      }
      .frame(maxWidth: 800)
    }
  }

  private func sendDraft() {
    guard !draft.isEmpty else { return }
    onSend?(draft)
    draft = ""
  }

  private var agentThinkingView: some View {
    HStack(spacing: 6) {
      Text("Agent")
        .font(.caption)
        .fontWeight(.semibold)
        .foregroundStyle(.purple)
      ProgressView()
        .controlSize(.mini)
      Text("Working...")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var statusColor: Color {
    switch session.status {
    case .running: .green
    case .idle: .gray
    case .stopped: .red
    }
  }
}

// MARK: - Session Message View

struct SessionMessageView: View {
  let message: MockMessage

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      switch message.role {
      case .user:
        userMessage
      case .assistant:
        assistantMessage
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var userMessage: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Text(message.author ?? "User")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.orange)
        Text(message.timestamp, style: .time)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Text(message.content)
        .font(.body)
        .textSelection(.enabled)
        .padding(10)
        .background(.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
  }

  private var assistantMessage: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Agent")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.purple)
        Text(message.timestamp, style: .time)
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Markdown(message.content)
        .textSelection(.enabled)

      ForEach(message.toolCalls) { tc in
        ToolCallRow(toolCall: tc)
      }
    }
  }
}

// MARK: - Tool Call Row

struct ToolCallRow: View {
  let toolCall: MockToolCall
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      Text(toolCall.result)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "gearshape")
          .font(.caption2)
          .foregroundStyle(.orange)
        Text(toolCall.name)
          .font(.system(.caption, design: .monospaced))
          .fontWeight(.medium)
        Text(toolCall.arguments)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .tint(.secondary)
    .padding(.vertical, 2)
  }
}
