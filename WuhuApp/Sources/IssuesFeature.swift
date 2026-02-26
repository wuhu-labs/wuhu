import ComposableArchitecture
import MarkdownUI
import SwiftUI

@Reducer
struct IssuesFeature {
  @ObservableState
  struct State {
    var issues: IdentifiedArrayOf<MockIssue> = []
    var selectedIssueID: String?
    var popoverIssueID: String?

    var selectedIssue: MockIssue? {
      guard let id = selectedIssueID else { return nil }
      return issues[id: id]
    }
  }

  enum Action {
    case issueSelected(String?)
    case popoverIssueChanged(String?)
    case issueContentLoaded(MockIssue)
    case issueContentLoadFailed
  }

  @Dependency(\.apiClient) var apiClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .issueSelected(id):
        state.selectedIssueID = id
        return .none

      case let .popoverIssueChanged(id):
        state.popoverIssueID = id
        guard let id else { return .none }
        guard let issue = state.issues[id: id] else { return .none }
        // If content is already loaded, don't re-fetch
        if !issue.markdownContent.isEmpty { return .none }
        return .run { send in
          let doc = try await apiClient.readWorkspaceDoc(id)
          await send(.issueContentLoaded(MockIssue.from(doc, existing: issue)))
        } catch: { _, send in
          await send(.issueContentLoadFailed)
        }

      case let .issueContentLoaded(issue):
        state.issues[id: issue.id] = issue
        return .none

      case .issueContentLoadFailed:
        return .none
      }
    }
  }
}

// MARK: - Issues List (content column)

struct IssuesListView: View {
  @Bindable var store: StoreOf<IssuesFeature>

  var body: some View {
    List(selection: $store.selectedIssueID.sending(\.issueSelected)) {
      ForEach(store.issues) { issue in
        IssueRow(issue: issue)
          .tag(issue.id)
      }
    }
    .listStyle(.inset)
    .navigationTitle("Issues")
  }
}

struct IssueRow: View {
  let issue: MockIssue

  var body: some View {
    HStack(spacing: 8) {
      Circle().fill(priorityColor).frame(width: 8, height: 8)
      VStack(alignment: .leading, spacing: 3) {
        Text(issue.title)
          .font(.callout)
          .fontWeight(.medium)
          .lineLimit(1)
        HStack(spacing: 6) {
          Text(issue.status.rawValue)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.15))
            .foregroundStyle(statusColor)
            .clipShape(Capsule())
          if let assignee = issue.assignee {
            Text(assignee)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(.vertical, 4)
  }

  private var priorityColor: Color {
    switch issue.priority {
    case .critical: .red
    case .high: .orange
    case .medium: .yellow
    case .low: .gray
    }
  }

  private var statusColor: Color {
    switch issue.status {
    case .open: .blue
    case .inProgress: .orange
    case .done: .green
    }
  }
}

// MARK: - Issues Detail (detail column — kanban)

struct IssuesDetailView: View {
  @Bindable var store: StoreOf<IssuesFeature>

  var body: some View {
    ScrollView([.horizontal, .vertical]) {
      HStack(alignment: .top, spacing: 16) {
        ForEach(MockIssue.IssueStatus.allCases, id: \.rawValue) { status in
          kanbanColumn(status: status)
        }
      }
      .padding(20)
    }
    .sheet(isPresented: Binding(
      get: { store.popoverIssueID != nil },
      set: { if !$0 { store.send(.popoverIssueChanged(nil)) } },
    )) {
      if let id = store.popoverIssueID, let issue = store.issues[id: id] {
        IssuePopoverContent(issue: issue) {
          store.send(.popoverIssueChanged(nil))
        }
      }
    }
  }

  private func kanbanColumn(status: MockIssue.IssueStatus) -> some View {
    let filtered = store.issues.filter { $0.status == status }
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Circle()
          .fill(columnColor(status))
          .frame(width: 10, height: 10)
        Text(status.rawValue)
          .font(.headline)
        Spacer()
        Text("\(filtered.count)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(.bottom, 4)

      ForEach(filtered) { issue in
        KanbanCard(issue: issue, isSelected: store.popoverIssueID == issue.id)
          .onTapGesture { store.send(.popoverIssueChanged(issue.id)) }
      }

      Spacer()
    }
    .frame(minWidth: 240, idealWidth: 280)
    .padding(14)
    .background(.background.secondary)
    .clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private func columnColor(_ status: MockIssue.IssueStatus) -> Color {
    switch status {
    case .open: .blue
    case .inProgress: .orange
    case .done: .green
    }
  }
}

// MARK: - Kanban Card

struct KanbanCard: View {
  let issue: MockIssue
  var isSelected = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(issue.title)
        .font(.callout)
        .fontWeight(.medium)
        .lineLimit(2)

      Text(issue.description)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(2)

      HStack(spacing: 6) {
        HStack(spacing: 3) {
          Circle().fill(priorityColor).frame(width: 6, height: 6)
          Text(issue.priority.rawValue)
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if let assignee = issue.assignee {
          Text(assignee)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.gray.opacity(0.12))
            .clipShape(Capsule())
        }
      }

      Text((issue.id.components(separatedBy: "/").last ?? issue.id).replacingOccurrences(of: ".md", with: ""))
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }
    .padding(10)
    .background(isSelected ? Color.orange.opacity(0.08) : cardBackgroundColor)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isSelected ? .orange : .clear, lineWidth: 1.5),
    )
    .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    .contentShape(Rectangle())
  }

  private var cardBackgroundColor: Color {
    #if os(macOS)
      Color(.windowBackgroundColor)
    #else
      Color(.systemBackground)
    #endif
  }

  private var priorityColor: Color {
    switch issue.priority {
    case .critical: .red
    case .high: .orange
    case .medium: .yellow
    case .low: .gray
    }
  }
}

// MARK: - Issue Popover Content

struct IssuePopoverContent: View {
  let issue: MockIssue
  var onDismiss: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text(issue.title)
          .font(.headline)
        Spacer()
        Button("Done") { onDismiss() }
          .keyboardShortcut(.cancelAction)
      }
      .padding(16)

      Divider()

      ScrollView {
        Markdown(issue.markdownContent)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(24)
      }
    }
    #if os(macOS)
    .frame(width: 640, height: 560)
    #endif
  }
}
