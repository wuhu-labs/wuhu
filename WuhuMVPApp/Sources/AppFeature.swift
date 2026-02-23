import ComposableArchitecture
import SwiftUI

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
    var channels: IdentifiedArrayOf<MockChannel> = MockData.channels
  }

  enum Action {
    case channelsExpandedChanged(Bool)
    case docs(DocsFeature.Action)
    case home(HomeFeature.Action)
    case issues(IssuesFeature.Action)
    case selectionChanged(SidebarSelection?)
    case sessions(SessionFeature.Action)
  }

  var body: some ReducerOf<Self> {
    Scope(state: \.home, action: \.home) { HomeFeature() }
    Scope(state: \.sessions, action: \.sessions) { SessionFeature() }
    Scope(state: \.issues, action: \.issues) { IssuesFeature() }
    Scope(state: \.docs, action: \.docs) { DocsFeature() }

    Reduce { state, action in
      switch action {
      case let .channelsExpandedChanged(expanded):
        state.channelsExpanded = expanded
        return .none
      case let .selectionChanged(selection):
        state.selection = selection
        return .none
      case .docs, .home, .issues, .sessions:
        return .none
      }
    }
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
  }

  // MARK: - Sidebar (column 1)

  private var sidebar: some View {
    List(selection: $store.selection.sending(\.selectionChanged)) {
      sidebarRow("Home", icon: "house", tag: .home)
      sidebarRow("Sessions", icon: "terminal", tag: .sessions, count: MockData.sessions.filter { $0.status == .running }.count)
      sidebarRow("Issues", icon: "checklist", tag: .issues, count: MockData.issues.filter { $0.status == .open }.count)
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
      } header: {
        Text("Channels")
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .top) {
      VStack(alignment: .leading, spacing: 2) {
        Text(MockData.workspaceName)
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
        ChannelChatView(channel: channel)
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
        }
      )
    }
    .windowStyle(.automatic)
    .defaultSize(width: 1200, height: 750)
  }
}

#Preview {
  AppView(
    store: Store(initialState: AppFeature.State()) {
      AppFeature()
    }
  )
}
