import ComposableArchitecture
import SwiftUI

@Reducer
struct SessionFeature {
  @ObservableState
  struct State {
    var sessions: IdentifiedArrayOf<MockSession> = MockData.sessions
    var selectedSessionID: String?

    var selectedSession: MockSession? {
      guard let id = selectedSessionID else { return nil }
      return sessions[id: id]
    }
  }

  enum Action {
    case sessionSelected(String?)
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .sessionSelected(id):
        state.selectedSessionID = id
        return .none
      }
    }
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
      }
    }
    .listStyle(.inset)
    .navigationTitle("Sessions")
  }
}

// MARK: - Session Detail (detail column)

struct SessionDetailView: View {
  let store: StoreOf<SessionFeature>

  var body: some View {
    if let session = store.selectedSession {
      SessionThreadView(session: session)
    } else {
      ContentUnavailableView(
        "No Session Selected",
        systemImage: "terminal",
        description: Text("Select a session to view its thread"),
      )
    }
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
  @State private var draft = ""

  var body: some View {
    VStack(spacing: 0) {
      // Status bar — full width
      HStack(spacing: 12) {
        Circle().fill(statusColor).frame(width: 8, height: 8)
        Text(session.title).font(.headline)
        Spacer()
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
          Button {
            // mockup no-op
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
      Text(message.content)
        .font(.body)
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
