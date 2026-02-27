import ComposableArchitecture
import IdentifiedCollections
import SwiftUI
import WuhuAPI
import WuhuCoreClient

// MARK: - Sidebar Selection

enum SidebarSelection: Hashable {
  case home
  case sessions
  case issues
  case docs
  case channel(String)
}

// MARK: - App Feature

@Reducer
struct AppFeature {
  @ObservableState
  struct State {
    var selection: SidebarSelection? = .home
    var channelsExpanded = true
    var home = HomeFeature.State()
    var sessions = SessionFeature.State()
    var issues = IssuesFeature.State()
    var docs = DocsFeature.State()
    var channels: IdentifiedArrayOf<MockChannel> = []
    var workspaceName = "Wuhu"
    var isLoading = false
    var hasLoaded = false
    var channelStreamingText: [String: String] = [:]
    @Presents var createChannel: CreateChannelFeature.State?
    @Presents var createSession: CreateChannelFeature.State?

    // Channel subscription state
    var activeChannelID: String?
    var channelTranscript: IdentifiedArrayOf<WuhuSessionEntry> = []
    var channelDisplayStartEntryID: Int64?
    var channelSubscribing = false
    var channelRetrying = false
    var channelRetryAttempt = 0
    var channelRetryDelaySeconds: Double = 0

    // Workspace state
    var workspaces: [Workspace] = []
    var activeWorkspace: Workspace = .default
    var isShowingWorkspaceSwitcher = false
  }

  enum Action {
    case onAppear
    case dataLoaded(
      sessions: IdentifiedArrayOf<MockSession>,
      channels: IdentifiedArrayOf<MockChannel>,
      docs: IdentifiedArrayOf<MockDoc>,
      issues: IdentifiedArrayOf<MockIssue>,
      events: [MockActivityEvent],
    )
    case loadFailed
    case refreshTick
    case refreshDataLoaded(
      sessions: IdentifiedArrayOf<MockSession>,
      channels: IdentifiedArrayOf<MockChannel>,
      docs: IdentifiedArrayOf<MockDoc>,
      issues: IdentifiedArrayOf<MockIssue>,
      events: [MockActivityEvent],
    )
    case channelRefreshTick(String)
    case channelsExpandedChanged(Bool)
    case channelSendMessage(channelID: String, message: String)
    case channelEnqueueSucceeded
    case channelUpdated(MockChannel)
    case channelLoadTranscript(String)
    case createChannelTapped
    case createChannel(PresentationAction<CreateChannelFeature.Action>)
    case createSessionTapped
    case createSession(PresentationAction<CreateChannelFeature.Action>)
    case docs(DocsFeature.Action)
    case home(HomeFeature.Action)
    case issues(IssuesFeature.Action)
    case selectionChanged(SidebarSelection?)
    case sessions(SessionFeature.Action)

    // Channel subscription lifecycle
    case channelStartSubscription(String)
    case channelInfoLoaded(WuhuGetSessionResponse)
    case channelSubscriptionInitial(SessionInitialState)
    case channelSubscriptionEvent(SessionEvent)
    case channelConnectionStateChanged(SSEConnectionState)
    case channelSubscriptionFailed(String)

    // Workspace
    case workspacesLoaded([Workspace], active: Workspace)
    case switchWorkspace(Workspace)
    case workspaceSwitcherToggled(Bool)
  }

  private enum CancelID {
    case refreshTimer
    case channelRefreshTimer
    case channelSubscription
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.continuousClock) var clock
  @Dependency(\.sessionTransportProvider) var sessionTransportProvider

  var body: some ReducerOf<Self> {
    Scope(state: \.home, action: \.home) { HomeFeature() }
    Scope(state: \.sessions, action: \.sessions) { SessionFeature() }
    Scope(state: \.issues, action: \.issues) { IssuesFeature() }
    Scope(state: \.docs, action: \.docs) { DocsFeature() }

    Reduce<State, Action> { state, action in
      switch action {
      case .onAppear:
        guard !state.hasLoaded else { return .none }
        state.isLoading = true
        state.hasLoaded = true

        // Load workspaces from storage
        let workspaces = WorkspaceStorage.loadWorkspaces()
        let activeID = WorkspaceStorage.loadActiveWorkspaceID()
        let active = workspaces.first(where: { $0.id == activeID }) ?? workspaces.first ?? .default
        state.workspaces = workspaces
        state.activeWorkspace = active
        state.workspaceName = active.name

        // Update the shared base URL
        if let url = URL(string: active.serverURL) {
          sharedBaseURL.update(url)
        }
        WorkspaceStorage.saveActiveWorkspaceID(active.id)

        let showArchived = state.sessions.showArchived
        return .run { send in
          async let sessionsResult = apiClient.listSessions(showArchived)
          async let docsResult = apiClient.listWorkspaceDocs()

          let allSessions = try await sessionsResult
          let allDocs = try await docsResult

          // Split sessions into coding sessions and channel sessions
          let codingSessions = allSessions.filter { $0.type == .coding || $0.type == .forkedChannel }
          let channelSessions = allSessions.filter { $0.type == .channel }

          let sortedCodingSessions = codingSessions.sorted(by: { $0.updatedAt > $1.updatedAt })
          // Fetch session details concurrently for accurate running status
          let detailedSessions = await withTaskGroup(of: MockSession.self) { group in
            for session in sortedCodingSessions {
              group.addTask {
                if let response = try? await apiClient.getSession(session.id) {
                  return MockSession.from(response)
                }
                return MockSession.from(session)
              }
            }
            var results: [MockSession] = []
            for await session in group {
              results.append(session)
            }
            return results.sorted(by: { $0.updatedAt > $1.updatedAt })
          }
          let mockSessions: IdentifiedArrayOf<MockSession> = IdentifiedArray(
            uniqueElements: detailedSessions,
          )
          let mockChannels: IdentifiedArrayOf<MockChannel> = IdentifiedArray(
            uniqueElements: channelSessions
              .sorted(by: { $0.updatedAt > $1.updatedAt })
              .map { MockChannel.from($0) },
          )

          // Parse workspace docs into docs and issues.
          // Use file path as the primary signal: files under "issues/" are
          // issues, everything else is a doc.
          var docsList: [MockDoc] = []
          var issuesList: [MockIssue] = []
          for doc in allDocs {
            if doc.path.hasPrefix("issues/"), let issue = MockIssue.from(doc) {
              issuesList.append(issue)
            } else {
              docsList.append(MockDoc.from(doc))
            }
          }

          // Derive activity feed from recent sessions
          let events: [MockActivityEvent] = allSessions
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .prefix(10)
            .enumerated()
            .map { index, session in
              let description = switch session.type {
              case .coding, .forkedChannel:
                "Session in \(session.environment.name) updated"
              case .channel:
                "Activity in #\(session.environment.name)"
              }
              return MockActivityEvent(
                id: "ev-\(index)",
                description: description,
                timestamp: session.updatedAt,
                icon: session.type == .channel ? "bubble.left.and.bubble.right" : "terminal",
              )
            }

          await send(.dataLoaded(
            sessions: mockSessions,
            channels: mockChannels,
            docs: IdentifiedArray(uniqueElements: docsList),
            issues: IdentifiedArray(uniqueElements: issuesList),
            events: events,
          ))
        } catch: { _, send in
          await send(.loadFailed)
        }

      case let .dataLoaded(sessions, channels, docs, issues, events):
        state.isLoading = false
        state.sessions.sessions = sessions
        state.channels = channels
        state.docs.docs = docs
        state.issues.issues = issues
        state.home.events = events
        return refreshTimerEffect()

      case .loadFailed:
        state.isLoading = false
        return .none

      case .refreshTick:
        let showArchived = state.sessions.showArchived
        return .run { send in
          async let sessionsResult = apiClient.listSessions(showArchived)
          async let docsResult = apiClient.listWorkspaceDocs()

          let allSessions = try await sessionsResult
          let allDocs = try await docsResult

          let codingSessions = allSessions.filter { $0.type == .coding || $0.type == .forkedChannel }
          let channelSessions = allSessions.filter { $0.type == .channel }

          let mockSessions: IdentifiedArrayOf<MockSession> = IdentifiedArray(
            uniqueElements: codingSessions
              .sorted(by: { $0.updatedAt > $1.updatedAt })
              .map { MockSession.from($0) },
          )
          let mockChannels: IdentifiedArrayOf<MockChannel> = IdentifiedArray(
            uniqueElements: channelSessions
              .sorted(by: { $0.updatedAt > $1.updatedAt })
              .map { MockChannel.from($0) },
          )

          var docsList: [MockDoc] = []
          var issuesList: [MockIssue] = []
          for doc in allDocs {
            if doc.path.hasPrefix("issues/"), let issue = MockIssue.from(doc) {
              issuesList.append(issue)
            } else {
              docsList.append(MockDoc.from(doc))
            }
          }

          let events: [MockActivityEvent] = allSessions
            .sorted(by: { $0.updatedAt > $1.updatedAt })
            .prefix(10)
            .enumerated()
            .map { index, session in
              let description = switch session.type {
              case .coding, .forkedChannel:
                "Session in \(session.environment.name) updated"
              case .channel:
                "Activity in #\(session.environment.name)"
              }
              return MockActivityEvent(
                id: "ev-\(index)",
                description: description,
                timestamp: session.updatedAt,
                icon: session.type == .channel ? "bubble.left.and.bubble.right" : "terminal",
              )
            }

          await send(.refreshDataLoaded(
            sessions: mockSessions,
            channels: mockChannels,
            docs: IdentifiedArray(uniqueElements: docsList),
            issues: IdentifiedArray(uniqueElements: issuesList),
            events: events,
          ))
        } catch: { _, _ in }

      case let .refreshDataLoaded(sessions, channels, docs, issues, events):
        // Merge sessions: preserve messages, detailed titles, and custom titles
        var mergedSessions: IdentifiedArrayOf<MockSession> = []
        for session in sessions {
          if var existing = state.sessions.sessions[id: session.id] {
            // Preserve running status: the list-sessions heuristic cannot detect
            // running state (only getSession can), so don't downgrade it.
            if existing.status != .running || session.status == .stopped {
              existing.status = session.status
            }
            existing.updatedAt = session.updatedAt
            existing.model = session.model
            existing.environmentName = session.environmentName
            existing.isArchived = session.isArchived
            // If the server returns a custom title, adopt it; otherwise preserve
            // any locally-set custom title from a prior rename.
            if let serverCustomTitle = session.customTitle {
              existing.customTitle = serverCustomTitle
              existing.title = serverCustomTitle
            }
            mergedSessions.append(existing)
          } else {
            mergedSessions.append(session)
          }
        }
        state.sessions.sessions = mergedSessions

        // Merge channels: update metadata but preserve loaded messages
        var mergedChannels: IdentifiedArrayOf<MockChannel> = []
        for channel in channels {
          if let existing = state.channels[id: channel.id] {
            var updated = channel
            updated.messages = existing.messages
            mergedChannels.append(updated)
          } else {
            mergedChannels.append(channel)
          }
        }
        state.channels = mergedChannels

        // Merge docs: preserve loaded markdownContent
        var mergedDocs: IdentifiedArrayOf<MockDoc> = []
        for doc in docs {
          if let existing = state.docs.docs[id: doc.id], !existing.markdownContent.isEmpty {
            var updated = doc
            updated.markdownContent = existing.markdownContent
            mergedDocs.append(updated)
          } else {
            mergedDocs.append(doc)
          }
        }
        state.docs.docs = mergedDocs

        // Merge issues: preserve loaded markdownContent
        var mergedIssues: IdentifiedArrayOf<MockIssue> = []
        for issue in issues {
          if let existing = state.issues.issues[id: issue.id], !existing.markdownContent.isEmpty {
            var updated = issue
            updated.markdownContent = existing.markdownContent
            mergedIssues.append(updated)
          } else {
            mergedIssues.append(issue)
          }
        }
        state.issues.issues = mergedIssues

        state.home.events = events
        return .none

      case let .channelRefreshTick(channelID):
        // If selection changed, just ignore this stale tick. Don't cancel the
        // shared timer — selectionChanged already cancels and restarts it for
        // the new channel, so cancelling here would kill the new timer.
        guard state.selection == .channel(channelID) else {
          return .none
        }
        return .run { send in
          let response = try await apiClient.getSession(channelID)
          let channel = MockChannel.from(response)
          await send(.channelUpdated(channel))
        } catch: { _, _ in }

      case let .channelUpdated(channel):
        state.channels[id: channel.id] = channel
        return .none

      case let .channelsExpandedChanged(expanded):
        state.channelsExpanded = expanded
        return .none

      case let .selectionChanged(selection):
        let previousSelection = state.selection
        state.selection = selection

        // Cancel channel subscription when navigating away from a channel
        var effects: [Effect<Action>] = []
        if case let .channel(prevChannelID) = previousSelection, selection != previousSelection {
          state.channelStreamingText[prevChannelID] = nil
          state.activeChannelID = nil
          state.channelTranscript = []
          state.channelDisplayStartEntryID = nil
          state.channelSubscribing = false
          state.channelRetrying = false
          effects.append(.cancel(id: CancelID.channelSubscription))
        }

        // Start subscription when selecting a channel
        if case let .channel(channelID) = selection {
          effects.append(.send(.channelStartSubscription(channelID)))
        }

        return effects.isEmpty ? .none : .merge(effects)

      case let .channelStartSubscription(channelID):
        state.activeChannelID = channelID
        state.channelTranscript = []
        state.channelDisplayStartEntryID = nil
        state.channelSubscribing = true

        // First fetch session info for displayStartEntryID, then subscribe
        return .merge(
          .cancel(id: CancelID.channelSubscription),
          .run { send in
            let response = try await apiClient.getSession(channelID)
            await send(.channelInfoLoaded(response))
          } catch: { error, send in
            await send(.channelSubscriptionFailed("\(error)"))
          },
        )

      case let .channelInfoLoaded(response):
        state.channelDisplayStartEntryID = response.session.displayStartEntryID

        // Pre-populate messages from REST while subscription connects
        let channel = MockChannel.from(response)
        state.channels[id: channel.id] = channel

        guard let channelID = state.activeChannelID else { return .none }
        let since = makeChannelSinceRequest(from: state)
        let transport = sessionTransportProvider.make()

        return .run { send in
          let result = try await transport.subscribeWithConnectionState(
            sessionID: .init(rawValue: channelID),
            since: since,
          )
          await send(.channelSubscriptionInitial(result.subscription.initial))

          await withTaskGroup(of: Void.self) { group in
            group.addTask {
              for await connectionState in result.connectionStates {
                await send(.channelConnectionStateChanged(connectionState))
              }
            }
            group.addTask {
              do {
                for try await event in result.subscription.events {
                  await send(.channelSubscriptionEvent(event))
                }
              } catch {
                if Task.isCancelled { return }
                await send(.channelSubscriptionFailed("\(error)"))
              }
            }
            await group.waitForAll()
          }
        } catch: { error, send in
          if Task.isCancelled { return }
          await send(.channelSubscriptionFailed("\(error)"))
        }
        .cancellable(id: CancelID.channelSubscription, cancelInFlight: true)

      case let .channelSubscriptionInitial(initial):
        state.channelSubscribing = false

        let filtered: [WuhuSessionEntry] = if let start = state.channelDisplayStartEntryID {
          initial.transcript.filter { $0.id >= start }
        } else {
          initial.transcript
        }
        state.channelTranscript = IdentifiedArray(uniqueElements: filtered)

        updateActiveChannelMessages(state: &state)

        // Restore in-flight streaming text on (re)connection
        if let channelID = state.activeChannelID {
          if let inflight = initial.inflightStreamText {
            state.channelStreamingText[channelID] = inflight
          } else {
            state.channelStreamingText[channelID] = nil
          }
        }

        return .none

      case let .channelSubscriptionEvent(event):
        applyChannelEvent(event, to: &state)
        if case .transcriptAppended = event {
          updateActiveChannelMessages(state: &state)
        }
        return .none

      case let .channelConnectionStateChanged(connectionState):
        switch connectionState {
        case .connecting:
          state.channelSubscribing = true
          state.channelRetrying = false
        case .connected:
          state.channelSubscribing = false
          state.channelRetrying = false
          state.channelRetryAttempt = 0
          state.channelRetryDelaySeconds = 0
        case let .retrying(attempt, delaySeconds):
          state.channelSubscribing = false
          state.channelRetrying = true
          state.channelRetryAttempt = attempt
          state.channelRetryDelaySeconds = delaySeconds
        case .closed:
          state.channelSubscribing = false
          state.channelRetrying = false
        }
        return .none

      case let .channelSubscriptionFailed(message):
        state.channelSubscribing = false
        state.channelRetrying = false
        // Could surface this to UI if needed
        _ = message
        return .none

      case let .channelLoadTranscript(channelID):
        // Now handled by channelStartSubscription
        return .send(.channelStartSubscription(channelID))

      case let .channelSendMessage(channelID, message):
        // Optimistically add the user message
        let username = UserDefaults.standard.string(forKey: "wuhuUsername")
        let trimmedUser = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        state.channels[id: channelID]?.messages.append(MockChannelMessage(
          id: UUID().uuidString,
          author: trimmedUser.isEmpty ? "You" : trimmedUser,
          isAgent: false,
          content: message,
          timestamp: Date(),
        ))
        // Just enqueue — subscription handles the response
        return .run { send in
          let user: String? = {
            let v = UserDefaults.standard.string(forKey: "wuhuUsername") ?? ""
            return v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : v
          }()
          _ = try await apiClient.enqueue(channelID, message, user, .followUp)
          await send(.channelEnqueueSucceeded)
        } catch: { _, _ in }

      case .channelEnqueueSucceeded:
        return .none

      case .createChannelTapped:
        state.createChannel = CreateChannelFeature.State()
        return .none

      case let .createChannel(.presented(.delegate(.created(session)))):
        state.createChannel = nil
        let channel = MockChannel.from(session)
        state.channels.append(channel)
        // Dispatch through selectionChanged so channel subscription starts
        return .send(.selectionChanged(.channel(channel.id)))

      case .createChannel(.presented(.delegate(.cancelled))):
        state.createChannel = nil
        return .none

      case .createChannel:
        return .none

      case .createSessionTapped:
        state.createSession = CreateChannelFeature.State(sessionType: .coding)
        return .none

      case let .createSession(.presented(.delegate(.created(session)))):
        state.createSession = nil
        let mockSession = MockSession.from(session)
        state.sessions.sessions.insert(mockSession, at: 0)
        state.selection = .sessions
        // Dispatch the action so SessionFeature starts the subscription
        return .send(.sessions(.sessionSelected(mockSession.id)))

      case .createSession(.presented(.delegate(.cancelled))):
        state.createSession = nil
        return .none

      case .createSession:
        return .none

      // MARK: - Workspace

      case let .workspacesLoaded(workspaces, active):
        state.workspaces = workspaces
        state.activeWorkspace = active
        state.workspaceName = active.name
        return .none

      case let .switchWorkspace(workspace):
        guard workspace.id != state.activeWorkspace.id else { return .none }

        // Update shared base URL
        if let url = URL(string: workspace.serverURL) {
          sharedBaseURL.update(url)
        }

        // Persist selection
        WorkspaceStorage.saveActiveWorkspaceID(workspace.id)

        // Update state
        state.activeWorkspace = workspace
        state.workspaceName = workspace.name
        state.isShowingWorkspaceSwitcher = false

        // Reset all loaded data
        state.selection = .home
        state.sessions.sessions = []
        state.sessions.selectedSessionID = nil
        state.channels = []
        state.docs.docs = []
        state.docs.selectedDocID = nil
        state.issues.issues = []
        state.issues.selectedIssueID = nil
        state.home.events = []
        state.activeChannelID = nil
        state.channelTranscript = []
        state.channelStreamingText = [:]

        // Mark as needing reload and trigger it
        state.hasLoaded = false
        state.isLoading = true
        state.hasLoaded = true

        // Cancel existing subscriptions and timers, then reload
        let showArchived = state.sessions.showArchived
        return .merge(
          .cancel(id: CancelID.refreshTimer),
          .cancel(id: CancelID.channelRefreshTimer),
          .cancel(id: CancelID.channelSubscription),
          .run { send in
            async let sessionsResult = apiClient.listSessions(showArchived)
            async let docsResult = apiClient.listWorkspaceDocs()

            let allSessions = try await sessionsResult
            let allDocs = try await docsResult

            let codingSessions = allSessions.filter { $0.type == .coding || $0.type == .forkedChannel }
            let channelSessions = allSessions.filter { $0.type == .channel }

            let sortedCodingSessions = codingSessions.sorted(by: { $0.updatedAt > $1.updatedAt })
            let detailedSessions = await withTaskGroup(of: MockSession.self) { group in
              for session in sortedCodingSessions {
                group.addTask {
                  if let response = try? await apiClient.getSession(session.id) {
                    return MockSession.from(response)
                  }
                  return MockSession.from(session)
                }
              }
              var results: [MockSession] = []
              for await session in group {
                results.append(session)
              }
              return results.sorted(by: { $0.updatedAt > $1.updatedAt })
            }
            let mockSessions: IdentifiedArrayOf<MockSession> = IdentifiedArray(
              uniqueElements: detailedSessions,
            )
            let mockChannels: IdentifiedArrayOf<MockChannel> = IdentifiedArray(
              uniqueElements: channelSessions
                .sorted(by: { $0.updatedAt > $1.updatedAt })
                .map { MockChannel.from($0) },
            )

            var docsList: [MockDoc] = []
            var issuesList: [MockIssue] = []
            for doc in allDocs {
              if doc.path.hasPrefix("issues/"), let issue = MockIssue.from(doc) {
                issuesList.append(issue)
              } else {
                docsList.append(MockDoc.from(doc))
              }
            }

            let events: [MockActivityEvent] = allSessions
              .sorted(by: { $0.updatedAt > $1.updatedAt })
              .prefix(10)
              .enumerated()
              .map { index, session in
                let description = switch session.type {
                case .coding, .forkedChannel:
                  "Session in \(session.environment.name) updated"
                case .channel:
                  "Activity in #\(session.environment.name)"
                }
                return MockActivityEvent(
                  id: "ev-\(index)",
                  description: description,
                  timestamp: session.updatedAt,
                  icon: session.type == .channel ? "bubble.left.and.bubble.right" : "terminal",
                )
              }

            await send(.dataLoaded(
              sessions: mockSessions,
              channels: mockChannels,
              docs: IdentifiedArray(uniqueElements: docsList),
              issues: IdentifiedArray(uniqueElements: issuesList),
              events: events,
            ))
          } catch: { _, send in
            await send(.loadFailed)
          },
        )

      case let .workspaceSwitcherToggled(shown):
        state.isShowingWorkspaceSwitcher = shown
        return .none

      case .docs, .home, .issues, .sessions:
        return .none
      }
    }
    .ifLet(\.$createChannel, action: \.createChannel) {
      CreateChannelFeature()
    }
    .ifLet(\.$createSession, action: \.createSession) {
      CreateChannelFeature()
    }
  }

  private func refreshTimerEffect() -> Effect<Action> {
    .run { send in
      for await _ in clock.timer(interval: .seconds(20)) {
        await send(.refreshTick)
      }
    }
    .cancellable(id: CancelID.refreshTimer, cancelInFlight: true)
  }

  private func channelRefreshTimerEffect(_ channelID: String) -> Effect<Action> {
    .run { send in
      for await _ in clock.timer(interval: .seconds(10)) {
        await send(.channelRefreshTick(channelID))
      }
    }
    .cancellable(id: CancelID.channelRefreshTimer, cancelInFlight: true)
  }

  // MARK: - Channel Helpers

  private func makeChannelSinceRequest(from state: State) -> SessionSubscriptionRequest {
    let transcriptSince = state.channelTranscript.last.map {
      TranscriptCursor(rawValue: String($0.id))
    }
    return SessionSubscriptionRequest(
      transcriptSince: transcriptSince,
      transcriptPageSize: 200,
    )
  }

  private func applyChannelEvent(_ event: SessionEvent, to state: inout State) {
    switch event {
    case let .transcriptAppended(entries):
      let filtered: [WuhuSessionEntry] = if let start = state.channelDisplayStartEntryID {
        entries.filter { $0.id >= start }
      } else {
        entries
      }
      for entry in filtered {
        state.channelTranscript[id: entry.id] = entry
      }

    case .systemUrgentQueue, .userQueue, .settingsUpdated, .statusUpdated:
      break

    case .streamBegan:
      if let channelID = state.activeChannelID {
        state.channelStreamingText[channelID] = ""
      }

    case let .streamDelta(delta):
      if let channelID = state.activeChannelID {
        state.channelStreamingText[channelID, default: ""] += delta
      }

    case .streamEnded:
      if let channelID = state.activeChannelID {
        state.channelStreamingText[channelID] = nil
      }
    }
  }

  private func updateActiveChannelMessages(state: inout State) {
    guard let channelID = state.activeChannelID else { return }
    let messages = TranscriptConverter.convertToChannelMessages(
      Array(state.channelTranscript),
      displayStartEntryID: state.channelDisplayStartEntryID,
    )
    state.channels[id: channelID]?.messages = messages
  }
}

// MARK: - App View (two-column NavigationSplitView)

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>
  #if os(iOS)
    @State private var isShowingSettings = false
  #endif

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detailColumn
    }
    .tint(.orange)
    #if os(macOS)
      .frame(minWidth: 900, minHeight: 600)
    #endif
      .task { store.send(.onAppear) }
      .sheet(item: $store.scope(state: \.createChannel, action: \.createChannel)) { store in
        CreateChannelView(store: store)
      }
      .sheet(item: $store.scope(state: \.createSession, action: \.createSession)) { store in
        CreateChannelView(store: store)
      }
    #if os(iOS)
      .sheet(isPresented: $isShowingSettings) {
        NavigationStack {
          SettingsView(
            workspaces: store.workspaces,
            activeWorkspace: store.activeWorkspace,
            onSwitchWorkspace: { ws in store.send(.switchWorkspace(ws)) },
          )
          .navigationTitle("Settings")
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { isShowingSettings = false }
            }
          }
        }
      }
    #endif
  }

  // MARK: - Sidebar (column 1)

  private var sidebar: some View {
    List(selection: $store.selection.sending(\.selectionChanged)) {
      sidebarRow("Home", icon: "house", tag: .home)
      sidebarRow(
        "Sessions", icon: "terminal", tag: .sessions,
        count: store.sessions.sessions.count(where: { $0.status == .running }),
      )
      sidebarRow(
        "Issues", icon: "checklist", tag: .issues,
        count: store.issues.issues.count(where: { $0.status == .open }),
      )
      sidebarRow("Docs", icon: "doc.text", tag: .docs)

      Section(isExpanded: $store.channelsExpanded.sending(\.channelsExpandedChanged)) {
        ForEach(store.channels) { channel in
          HStack {
            Text(channel.name)
            Spacer()
            if channel.unreadCount > 0 {
              Text("\(channel.unreadCount)")
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.orange)
                .foregroundStyle(.white)
                .clipShape(Capsule())
            }
          }
          .tag(SidebarSelection.channel(channel.id))
        }
        Button {
          store.send(.createChannelTapped)
        } label: {
          HStack {
            Image(systemName: "plus")
            Text("New Channel")
          }
          .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
      } header: {
        Text("Channels")
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .top) {
      workspaceSwitcherHeader
    }
    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        HStack(spacing: 4) {
          Button {
            store.send(.refreshTick)
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .help("Refresh")

          Button {
            store.send(.createSessionTapped)
          } label: {
            Image(systemName: "plus")
          }
          .help("New Session")

          #if os(iOS)
            Button {
              isShowingSettings = true
            } label: {
              Image(systemName: "gearshape")
            }
            .help("Settings")
          #endif
        }
      }
    }
  }

  // MARK: - Workspace Switcher Header

  private var workspaceSwitcherHeader: some View {
    Menu {
      ForEach(store.workspaces, id: \.id) { workspace in
        Button {
          store.send(.switchWorkspace(workspace))
        } label: {
          HStack {
            Text(workspace.name)
            if workspace.id == store.activeWorkspace.id {
              Image(systemName: "checkmark")
            }
          }
        }
      }
    } label: {
      HStack(spacing: 6) {
        VStack(alignment: .leading, spacing: 1) {
          Text(store.workspaceName)
            .font(.headline)
            .foregroundStyle(.primary)
          Text(store.activeWorkspace.serverURL)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        }
        Spacer()
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func sidebarRow(_ title: String, icon: String, tag: SidebarSelection, count: Int = 0) -> some View {
    Label {
      HStack {
        Text(title)
        Spacer()
        if count > 0 {
          Text("\(count)")
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.orange.opacity(0.2))
            .foregroundStyle(.orange)
            .clipShape(Capsule())
        }
      }
    } icon: {
      Image(systemName: icon)
    }
    .tag(tag)
  }

  // MARK: - Detail

  @ViewBuilder
  private var detailColumn: some View {
    switch store.selection {
    case .home:
      dualPane {
        HomeListView(store: store.scope(state: \.home, action: \.home))
      } detail: {
        HomeDetailView(store: store.scope(state: \.home, action: \.home))
      }
    case .sessions:
      dualPane {
        SessionListView(store: store.scope(state: \.sessions, action: \.sessions))
      } detail: {
        SessionDetailView(store: store.scope(state: \.sessions, action: \.sessions))
      }
    case .issues:
      IssuesDetailView(store: store.scope(state: \.issues, action: \.issues))
    case .docs:
      dualPane {
        DocsListView(store: store.scope(state: \.docs, action: \.docs))
      } detail: {
        DocsDetailView(store: store.scope(state: \.docs, action: \.docs))
      }
    case let .channel(channelID):
      if let channel = store.channels[id: channelID] {
        ChannelChatView(
          channel: channel,
          streamingText: store.channelStreamingText[channelID] ?? "",
          onSend: { message in
            store.send(.channelSendMessage(channelID: channelID, message: message))
          },
        )
      }
    case nil:
      ContentUnavailableView("Select an item", systemImage: "sidebar.left", description: Text("Choose something from the sidebar"))
    }
  }

  /// On macOS, renders a fixed-width list alongside the detail view.
  /// On iOS, renders the list with a navigation push to the detail.
  private func dualPane(
    @ViewBuilder list: () -> some View,
    @ViewBuilder detail: () -> some View,
  ) -> some View {
    #if os(macOS)
      HStack(spacing: 0) {
        list()
          .frame(width: 280)
        Divider()
        detail()
          .frame(maxWidth: .infinity)
      }
    #else
      NavigationStack {
        list()
          .navigationDestination(isPresented: Binding(
            get: { hasDetailSelection },
            set: { if !$0 { clearDetailSelection() } },
          )) {
            detail()
          }
      }
    #endif
  }

  #if os(iOS)
    /// Whether the current top-level section has a selected detail item.
    private var hasDetailSelection: Bool {
      switch store.selection {
      case .sessions: store.sessions.selectedSessionID != nil
      case .home: store.home.selectedEventID != nil
      case .docs: store.docs.selectedDocID != nil
      default: false
      }
    }

    /// Clear the detail selection for the current section (on back navigation).
    private func clearDetailSelection() {
      switch store.selection {
      case .sessions: store.send(.sessions(.sessionSelected(nil)))
      case .home: store.send(.home(.eventSelected(nil)))
      case .docs: store.send(.docs(.docSelected(nil)))
      default: break
      }
    }
  #endif
}

// MARK: - Entry Point

@main
struct WuhuApp: App {
  var body: some Scene {
    WindowGroup {
      AppView(
        store: Store(initialState: AppFeature.State()) {
          AppFeature()
        },
      )
    }
    #if os(macOS)
    .windowStyle(.automatic)
    .defaultSize(width: 1200, height: 750)
    #endif

    #if os(macOS)
      Settings {
        SettingsView(
          workspaces: WorkspaceStorage.loadWorkspaces(),
          activeWorkspace: {
            let ws = WorkspaceStorage.loadWorkspaces()
            let id = WorkspaceStorage.loadActiveWorkspaceID()
            return ws.first(where: { $0.id == id }) ?? ws.first ?? .default
          }(),
          onSwitchWorkspace: nil,
        )
      }
    #endif
  }
}

// MARK: - Settings

struct SettingsView: View {
  @AppStorage("wuhuUsername") private var username = ""
  @State private var workspaces: [Workspace]
  @State private var activeWorkspace: Workspace
  var onSwitchWorkspace: ((Workspace) -> Void)?

  @State private var isAddingWorkspace = false
  @State private var newWorkspaceName = ""
  @State private var newWorkspaceURL = "http://localhost:8080"

  @State private var editingWorkspace: Workspace?
  @State private var editName = ""
  @State private var editURL = ""

  init(
    workspaces: [Workspace],
    activeWorkspace: Workspace,
    onSwitchWorkspace: ((Workspace) -> Void)?,
  ) {
    _workspaces = State(initialValue: workspaces)
    _activeWorkspace = State(initialValue: activeWorkspace)
    self.onSwitchWorkspace = onSwitchWorkspace
  }

  var body: some View {
    Form {
      Section("Workspaces") {
        ForEach(workspaces, id: \.id) { workspace in
          HStack {
            VStack(alignment: .leading, spacing: 2) {
              HStack(spacing: 6) {
                Text(workspace.name)
                  .fontWeight(workspace.id == activeWorkspace.id ? .semibold : .regular)
                if workspace.id == activeWorkspace.id {
                  Text("Active")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
                }
              }
              Text(workspace.serverURL)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if workspace.id != activeWorkspace.id {
              Button("Switch") {
                switchTo(workspace)
              }
              .buttonStyle(.borderless)
            }
            Button {
              editingWorkspace = workspace
              editName = workspace.name
              editURL = workspace.serverURL
            } label: {
              Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            if workspaces.count > 1 {
              Button(role: .destructive) {
                removeWorkspace(workspace)
              } label: {
                Image(systemName: "trash")
              }
              .buttonStyle(.borderless)
            }
          }
          .padding(.vertical, 2)
        }

        Button {
          isAddingWorkspace = true
          newWorkspaceName = ""
          newWorkspaceURL = "http://localhost:8080"
        } label: {
          Label("Add Workspace", systemImage: "plus")
        }
      }

      Section("Identity") {
        TextField("Username", text: $username)
          .textFieldStyle(.roundedBorder)
        Text("Displayed as the author of your messages.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    #if os(macOS)
      .frame(width: 480)
    #endif
      .alert("Add Workspace", isPresented: $isAddingWorkspace) {
        TextField("Name", text: $newWorkspaceName)
        TextField("Server URL", text: $newWorkspaceURL)
        Button("Add") { addWorkspace() }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Enter a name and server URL for the new workspace.")
      }
      .alert("Edit Workspace", isPresented: Binding(
        get: { editingWorkspace != nil },
        set: { if !$0 { editingWorkspace = nil } },
      )) {
        TextField("Name", text: $editName)
        TextField("Server URL", text: $editURL)
        Button("Save") { saveEditedWorkspace() }
        Button("Cancel", role: .cancel) { editingWorkspace = nil }
      } message: {
        Text("Update the workspace name and server URL.")
      }
  }

  private func addWorkspace() {
    let name = newWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = newWorkspaceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !url.isEmpty else { return }
    let workspace = Workspace(name: name, serverURL: url)
    workspaces.append(workspace)
    WorkspaceStorage.saveWorkspaces(workspaces)
  }

  private func removeWorkspace(_ workspace: Workspace) {
    workspaces.removeAll { $0.id == workspace.id }
    WorkspaceStorage.saveWorkspaces(workspaces)
    // If we removed the active one, switch to the first available
    if workspace.id == activeWorkspace.id, let first = workspaces.first {
      switchTo(first)
    }
  }

  private func switchTo(_ workspace: Workspace) {
    activeWorkspace = workspace
    WorkspaceStorage.saveActiveWorkspaceID(workspace.id)
    onSwitchWorkspace?(workspace)
  }

  private func saveEditedWorkspace() {
    guard let editing = editingWorkspace else { return }
    let name = editName.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = editURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !url.isEmpty else { return }

    if let index = workspaces.firstIndex(where: { $0.id == editing.id }) {
      workspaces[index].name = name
      workspaces[index].serverURL = url
      WorkspaceStorage.saveWorkspaces(workspaces)

      // If we edited the active workspace, update it and notify
      if editing.id == activeWorkspace.id {
        activeWorkspace = workspaces[index]
        // Update shared URL and notify reducer
        if let parsedURL = URL(string: url) {
          sharedBaseURL.update(parsedURL)
        }
        onSwitchWorkspace?(workspaces[index])
      }
    }
    editingWorkspace = nil
  }
}

#Preview {
  AppView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    },
  )
}
