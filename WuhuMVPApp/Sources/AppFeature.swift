import ComposableArchitecture
import IdentifiedCollections
import SwiftUI
import WuhuAPI

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
    case channelStreamDelta(channelID: String, delta: String)
    case channelStreamCompleted(channelID: String)
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
  }

  private enum CancelID {
    case refreshTimer
    case channelRefreshTimer
  }

  @Dependency(\.apiClient) var apiClient
  @Dependency(\.continuousClock) var clock

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
        return .run { send in
          async let sessionsResult = apiClient.listSessions()
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

          // Parse workspace docs into docs and issues
          var docsList: [MockDoc] = []
          var issuesList: [MockIssue] = []
          for doc in allDocs {
            if let issue = MockIssue.from(doc) {
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
        return .run { send in
          async let sessionsResult = apiClient.listSessions()
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
            if let issue = MockIssue.from(doc) {
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
        // Merge sessions: preserve messages and detailed titles
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

      case let .channelsExpandedChanged(expanded):
        state.channelsExpanded = expanded
        return .none

      case let .selectionChanged(selection):
        state.selection = selection
        if case let .channel(channelID) = selection {
          if let channel = state.channels[id: channelID], channel.messages.isEmpty {
            return .merge(
              .send(.channelLoadTranscript(channelID)),
              channelRefreshTimerEffect(channelID),
            )
          }
          return channelRefreshTimerEffect(channelID)
        }
        return .cancel(id: CancelID.channelRefreshTimer)

      case let .channelLoadTranscript(channelID):
        return .run { send in
          let response = try await apiClient.getSession(channelID)
          let channel = MockChannel.from(response)
          await send(.channelUpdated(channel))
        } catch: { _, _ in }

      case let .channelSendMessage(channelID, message):
        // Optimistically add the user message
        state.channels[id: channelID]?.messages.append(MockChannelMessage(
          id: UUID().uuidString,
          author: "You",
          isAgent: false,
          content: message,
          timestamp: Date(),
        ))
        state.channelStreamingText[channelID] = ""
        return .run { send in
          let user: String? = {
            let v = UserDefaults.standard.string(forKey: "wuhuUsername") ?? ""
            return v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : v
          }()
          _ = try await apiClient.enqueue(channelID, message, user)
          let stream = try await apiClient.followSessionStream(channelID, nil)
          for try await event in stream {
            switch event {
            case .idle, .done:
              await send(.channelStreamCompleted(channelID: channelID))
              return
            case let .assistantTextDelta(delta):
              await send(.channelStreamDelta(channelID: channelID, delta: delta))
            case .entryAppended:
              break
            }
          }
          // Stream ended without idle/done — re-fetch anyway
          await send(.channelStreamCompleted(channelID: channelID))
        } catch: { _, send in
          await send(.channelStreamCompleted(channelID: channelID))
        }

      case let .channelStreamDelta(channelID, delta):
        state.channelStreamingText[channelID, default: ""] += delta
        return .none

      case let .channelStreamCompleted(channelID):
        state.channelStreamingText[channelID] = nil
        return .run { send in
          let response = try await apiClient.getSession(channelID)
          let channel = MockChannel.from(response)
          await send(.channelUpdated(channel))
        } catch: { _, _ in }

      case let .channelUpdated(channel):
        state.channels[id: channel.id] = channel
        return .none

      case .createChannelTapped:
        state.createChannel = CreateChannelFeature.State()
        return .none

      case let .createChannel(.presented(.delegate(.created(session)))):
        state.createChannel = nil
        let channel = MockChannel.from(session)
        state.channels.append(channel)
        state.selection = .channel(channel.id)
        return .none

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
        state.sessions.selectedSessionID = mockSession.id
        return .none

      case .createSession(.presented(.delegate(.cancelled))):
        state.createSession = nil
        return .none

      case .createSession:
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
}

// MARK: - App View (two-column NavigationSplitView)

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detailColumn
    }
    .tint(.orange)
    .frame(minWidth: 900, minHeight: 600)
    .task { store.send(.onAppear) }
    .sheet(item: $store.scope(state: \.createChannel, action: \.createChannel)) { store in
      CreateChannelView(store: store)
    }
    .sheet(item: $store.scope(state: \.createSession, action: \.createSession)) { store in
      CreateChannelView(store: store)
    }
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
      VStack(alignment: .leading, spacing: 2) {
        Text(store.workspaceName)
          .font(.headline)
        Text("Workspace")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
    }
    .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Button {
          store.send(.refreshTick)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .help("Refresh")
      }
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.createSessionTapped)
        } label: {
          Image(systemName: "plus")
        }
        .help("New Session")
      }
    }
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
      HStack(spacing: 0) {
        HomeListView(store: store.scope(state: \.home, action: \.home))
          .frame(width: 280)
        Divider()
        HomeDetailView(store: store.scope(state: \.home, action: \.home))
          .frame(maxWidth: .infinity)
      }
    case .sessions:
      HStack(spacing: 0) {
        SessionListView(store: store.scope(state: \.sessions, action: \.sessions))
          .frame(width: 280)
        Divider()
        SessionDetailView(store: store.scope(state: \.sessions, action: \.sessions))
          .frame(maxWidth: .infinity)
      }
    case .issues:
      IssuesDetailView(store: store.scope(state: \.issues, action: \.issues))
    case .docs:
      HStack(spacing: 0) {
        DocsListView(store: store.scope(state: \.docs, action: \.docs))
          .frame(width: 280)
        Divider()
        DocsDetailView(store: store.scope(state: \.docs, action: \.docs))
          .frame(maxWidth: .infinity)
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
}

// MARK: - Entry Point

@main
struct WuhuMVPApp: App {
  var body: some Scene {
    WindowGroup {
      AppView(
        store: Store(initialState: AppFeature.State()) {
          AppFeature()
        },
      )
    }
    .windowStyle(.automatic)
    .defaultSize(width: 1200, height: 750)
    Settings {
      SettingsView()
    }
  }
}

// MARK: - Settings

struct SettingsView: View {
  @AppStorage("wuhuServerURL") private var serverURL = "http://localhost:8080"
  @AppStorage("wuhuUsername") private var username = ""

  var body: some View {
    Form {
      Section("Server") {
        TextField("Wuhu Server URL", text: $serverURL)
          .textFieldStyle(.roundedBorder)
        Text("Restart the app after changing the server URL.")
          .font(.caption)
          .foregroundStyle(.secondary)
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
    .frame(width: 400)
  }
}

#Preview {
  AppView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    },
  )
}
