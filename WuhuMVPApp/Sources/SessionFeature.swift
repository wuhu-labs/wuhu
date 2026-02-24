import ComposableArchitecture
import MarkdownUI
import SwiftUI

@Reducer
struct SessionFeature {
  @ObservableState
  struct State {
    var sessions: IdentifiedArrayOf<MockSession> = []
    var selectedSessionID: String?
    var isLoadingDetail = false
    var streamingText = ""
    var headEntryID: Int64?

    var selectedSession: MockSession? {
      guard let id = selectedSessionID else { return nil }
      return sessions[id: id]
    }
  }

  enum Action {
    case sessionSelected(String?)
    case sessionDetailLoaded(MockSession, headEntryID: Int64)
    case sessionDetailLoadFailed
    case sendMessage(String)
    case streamDelta(String)
    case streamCompleted(String)
    case streamFailed
  }

  @Dependency(\.apiClient) var apiClient

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .sessionSelected(id):
        state.selectedSessionID = id
        state.streamingText = ""
        guard let id else {
          state.isLoadingDetail = false
          return .none
        }
        state.isLoadingDetail = true
        return .run { send in
          let response = try await apiClient.getSession(id)
          let session = MockSession.from(response)
          await send(.sessionDetailLoaded(session, headEntryID: response.session.headEntryID))
        } catch: { _, send in
          await send(.sessionDetailLoadFailed)
        }

      case let .sessionDetailLoaded(session, headEntryID):
        state.isLoadingDetail = false
        state.headEntryID = headEntryID
        state.sessions[id: session.id] = session
        return .none

      case .sessionDetailLoadFailed:
        state.isLoadingDetail = false
        return .none

      case let .sendMessage(content):
        guard let sessionID = state.selectedSessionID else { return .none }
        let sinceCursor = state.headEntryID
        state.streamingText = ""
        // Optimistically add user message
        state.sessions[id: sessionID]?.messages.append(MockMessage(
          role: .user,
          content: content,
          timestamp: Date(),
        ))
        return .run { send in
          let user: String? = {
            let v = UserDefaults.standard.string(forKey: "wuhuUsername") ?? ""
            return v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : v
          }()
          _ = try await apiClient.enqueue(sessionID, content, user)
          let stream = try await apiClient.followSessionStream(sessionID, sinceCursor)
          for try await event in stream {
            switch event {
            case let .assistantTextDelta(delta):
              await send(.streamDelta(delta))
            case .idle, .done:
              await send(.streamCompleted(sessionID))
              return
            case .entryAppended:
              break
            }
          }
          await send(.streamCompleted(sessionID))
        } catch: { _, send in
          await send(.streamFailed)
        }

      case let .streamDelta(delta):
        state.streamingText += delta
        return .none

      case let .streamCompleted(sessionID):
        state.streamingText = ""
        return .run { send in
          let response = try await apiClient.getSession(sessionID)
          let session = MockSession.from(response)
          await send(.sessionDetailLoaded(session, headEntryID: response.session.headEntryID))
        } catch: { _, send in
          await send(.streamFailed)
        }

      case .streamFailed:
        state.streamingText = ""
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
  @Bindable var store: StoreOf<SessionFeature>

  var body: some View {
    if store.isLoadingDetail {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else if let session = store.selectedSession {
      SessionThreadView(
        session: session,
        streamingText: store.streamingText,
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
  var streamingText: String = ""
  var onSend: ((String) -> Void)?
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
            if !streamingText.isEmpty {
              streamingMessageView
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

  private var streamingMessageView: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 6) {
        Text("Agent")
          .font(.caption)
          .fontWeight(.semibold)
          .foregroundStyle(.purple)
        ProgressView()
          .controlSize(.mini)
      }
      Markdown(streamingText)
        .textSelection(.enabled)
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
