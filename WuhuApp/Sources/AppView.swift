import ComposableArchitecture
import SwiftUI
import WuhuAPI

struct AppView: View {
  @Bindable var store: StoreOf<AppFeature>

  @Environment(\.scenePhase) private var scenePhase

  var body: some View {
    NavigationSplitView {
      sidebarColumn
    } content: {
      contentColumn
    } detail: {
      detailColumn
    }
    .onAppear { store.send(.onAppear) }
    .onChange(of: scenePhase) { _, newPhase in
      store.send(.scenePhaseChanged(newPhase))
    }
    .sheet(store: store.scope(state: \.$createSession, action: \.createSession)) { createStore in
      CreateSessionView(store: createStore)
    }
  }

  // MARK: - Sidebar

  private var sidebarColumn: some View {
    List(selection: $store.sidebarItem) {
      Section {
        ForEach(AppFeature.SidebarItem.allCases) { item in
          Label(item.label, systemImage: item.systemImage)
            .tag(item)
        }
      }

      Section {
        Button {
          store.send(.binding(.set(\.isShowingSettings, true)))
        } label: {
          Label("Settings", systemImage: "gear")
        }
      }
    }
    .navigationTitle("Wuhu")
    .sheet(
      isPresented: $store.isShowingSettings,
    ) {
      NavigationStack {
        SettingsView(store: store.scope(state: \.settings, action: \.settings))
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") {
                store.send(.binding(.set(\.isShowingSettings, false)))
              }
            }
          }
      }
    }
  }

  // MARK: - Content Column

  @ViewBuilder
  private var contentColumn: some View {
    switch store.sidebarItem {
    case .home:
      HomeView()
    case .channels:
      channelsListContent
    case .sessions:
      sessionsListContent
    case .issues:
      issuesListContent
    case .docs:
      docsListContent
    case .none:
      Text("Select an item")
        .foregroundStyle(.secondary)
    }
  }

  private var sessionsListContent: some View {
    SessionsListView(
      store: store.scope(state: \.sessions, action: \.sessions),
      selection: $store.selectedSessionID,
      filter: .coding,
      onCreateTapped: { store.send(.createSessionTapped) },
    )
  }

  private var channelsListContent: some View {
    SessionsListView(
      store: store.scope(state: \.sessions, action: \.sessions),
      selection: $store.selectedChannelID,
      filter: .channel,
      onCreateTapped: { store.send(.createSessionTapped) },
    )
  }

  private var docsListContent: some View {
    DocsListView(
      store: store.scope(state: \.workspace, action: \.workspace),
      selection: $store.selectedDocPath,
    )
  }

  private var issuesListContent: some View {
    IssuesListView(
      store: store.scope(state: \.workspace, action: \.workspace),
      selection: $store.selectedDocPath,
    )
  }

  // MARK: - Detail Column

  @ViewBuilder
  private var detailColumn: some View {
    if store.sidebarItem == .sessions || store.sidebarItem == .home {
      if let detailStore = store.scope(state: \.sessionDetail, action: \.sessionDetail) {
        SessionDetailView(store: detailStore)
      } else {
        ContentUnavailableView("Select a session", systemImage: "terminal", description: Text("Choose a session from the list"))
      }
    } else if store.sidebarItem == .channels {
      if let detailStore = store.scope(state: \.channelDetail, action: \.channelDetail) {
        ChannelDetailView(store: detailStore)
      } else {
        ContentUnavailableView("Select a channel", systemImage: "bubble.left.and.bubble.right", description: Text("Choose a channel from the list"))
      }
    } else if store.sidebarItem == .docs || store.sidebarItem == .issues {
      if let detailStore = store.scope(state: \.docDetail, action: \.docDetail) {
        WorkspaceDocDetailView(store: detailStore)
      } else {
        ContentUnavailableView("Select a document", systemImage: "doc.text", description: Text("Choose a document from the list"))
      }
    } else {
      ContentUnavailableView("Select an item", systemImage: "sidebar.left", description: Text("Choose something from the sidebar"))
    }
  }
}
