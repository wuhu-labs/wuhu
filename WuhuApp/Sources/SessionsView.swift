import ComposableArchitecture
import SwiftUI
import WuhuAPI

struct SessionsListView: View {
  @Bindable var store: StoreOf<SessionsFeature>
  @Binding var selection: String?
  var filter: WuhuSessionType
  var onCreateTapped: () -> Void

  var body: some View {
    List(selection: $selection) {
      if let error = store.error {
        Section {
          Text(error)
            .foregroundStyle(.red)
        }
      }

      ForEach(groupedSections, id: \.title) { section in
        Section(section.title) {
          ForEach(section.sessions) { session in
            SessionRowView(session: session)
              .tag(session.id)
          }
        }
      }
    }
    .navigationTitle(filter == .channel ? "Channels" : "Sessions")
    .searchable(text: $store.searchText, placement: .sidebar)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          onCreateTapped()
        } label: {
          Image(systemName: "plus")
        }
        .disabled(store.serverURL == nil)
      }

      if store.isLoading {
        ToolbarItem(placement: .automatic) {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
    .refreshable {
      await store.send(.refresh).finish()
    }
    .overlay {
      if filteredSessions.isEmpty, !store.isLoading, store.error == nil {
        ContentUnavailableView(
          "No \(filter == .channel ? "Channels" : "Sessions")",
          systemImage: filter == .channel ? "bubble.left.and.bubble.right" : "terminal",
          description: Text(store.serverURL == nil ? "Configure a server in Settings" : ""),
        )
      }
    }
  }

  private var filteredSessions: [WuhuSession] {
    var result = Array(store.sessions).filter { $0.type == filter }

    let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !query.isEmpty {
      result = result.filter { session in
        session.id.lowercased().contains(query)
          || session.model.lowercased().contains(query)
          || session.environment.name.lowercased().contains(query)
          || session.provider.rawValue.lowercased().contains(query)
      }
    }

    return result
  }

  private var groupedSections: [SessionSection] {
    let sessions = filteredSessions
    if sessions.isEmpty { return [] }

    let now = Date()
    let calendar = Calendar.current

    var active: [WuhuSession] = []
    var today: [WuhuSession] = []
    var thisWeek: [WuhuSession] = []
    var older: [WuhuSession] = []

    for session in sessions {
      let age = now.timeIntervalSince(session.updatedAt)
      if age < 300 {
        active.append(session)
      } else if calendar.isDateInToday(session.updatedAt) {
        today.append(session)
      } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now),
                session.updatedAt > weekAgo
      {
        thisWeek.append(session)
      } else {
        older.append(session)
      }
    }

    var sections: [SessionSection] = []
    if !active.isEmpty { sections.append(.init(title: "Active", sessions: active)) }
    if !today.isEmpty { sections.append(.init(title: "Today", sessions: today)) }
    if !thisWeek.isEmpty { sections.append(.init(title: "This Week", sessions: thisWeek)) }
    if !older.isEmpty { sections.append(.init(title: "Older", sessions: older)) }
    return sections
  }
}

private struct SessionSection {
  var title: String
  var sessions: [WuhuSession]
}

struct SessionRowView: View {
  let session: WuhuSession

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(sessionTitle)
        .font(.subheadline)
        .fontWeight(.medium)
        .lineLimit(1)

      HStack(spacing: 6) {
        Text(session.provider.rawValue)
        Text("·")
        Text(session.model)
        if let runner = session.runnerName {
          Text("·")
          Text(runner)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)

      HStack(spacing: 6) {
        Text(session.environment.name)
        Text("·")
        Text(session.updatedAt, style: .relative)
      }
      .font(.caption)
      .foregroundStyle(.tertiary)
      .lineLimit(1)
    }
    .padding(.vertical, 2)
  }

  private var sessionTitle: String {
    let shortID = String(session.id.prefix(12))
    return "\(shortID)..."
  }
}
