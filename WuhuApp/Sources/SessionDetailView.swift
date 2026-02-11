import ComposableArchitecture
import PiAI
import SwiftUI
import WuhuAPI

struct SessionDetailView: View {
  let store: StoreOf<SessionDetailFeature>

  var body: some View {
    WithPerceptionTracking {
      VStack(spacing: 0) {
        header
        Divider()
        transcript
        Divider()
        composer
      }
      .navigationTitle("Session")
      .navigationBarTitleDisplayMode(.inline)
      .task { await store.send(.onAppear).finish() }
      .onDisappear { store.send(.onDisappear) }
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Picker(
        "Verbosity",
        selection: Binding(
          get: { store.verbosity },
          set: { store.send(.binding(.set(\.verbosity, $0))) },
        ),
      ) {
        Text("Minimal").tag(SessionDetailFeature.Verbosity.minimal)
        Text("Compact").tag(SessionDetailFeature.Verbosity.compact)
      }
      .pickerStyle(.segmented)

      if store.isLoading {
        ProgressView()
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 10) {
          if let error = store.error {
            Text(error)
              .foregroundStyle(.red)
              .padding(.horizontal)
          }

          ForEach(store.transcript) { entry in
            if let view = EntryView(entry: entry, verbosity: store.verbosity) {
              view
                .id(entry.id)
            }
          }

          if !store.streamingAssistantText.isEmpty {
            MessageBubble(
              role: "assistant",
              title: "Assistant (streaming)",
              text: store.streamingAssistantText,
              isCompact: store.verbosity == .compact,
            )
            .padding(.horizontal)
            .id("streaming")
          }
        }
        .padding(.vertical, 12)
      }
      .onChange(of: store.transcript.last?.id) { lastID in
        guard let lastID else { return }
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(lastID, anchor: .bottom)
        }
      }
      .onChange(of: store.streamingAssistantText) { _ in
        guard !store.streamingAssistantText.isEmpty else { return }
        proxy.scrollTo("streaming", anchor: .bottom)
      }
    }
  }

  private var composer: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField(
        "Message",
        text: Binding(
          get: { store.draft },
          set: { store.send(.binding(.set(\.draft, $0))) },
        ),
        axis: .vertical,
      )
      .lineLimit(1 ... 6)
      .textInputAutocapitalization(.sentences)

      Button {
        store.send(.sendTapped)
      } label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 22))
      }
      .disabled(store.isSending || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }
}

private func EntryView(entry: WuhuSessionEntry, verbosity: SessionDetailFeature.Verbosity) -> AnyView? {
  switch entry.payload {
  case let .message(message):
    return AnyView(
      MessageBubble(
        role: roleLabel(message),
        title: titleLabel(message, verbosity: verbosity),
        text: messageText(message, verbosity: verbosity),
        isCompact: verbosity == .compact,
      )
      .padding(.horizontal),
    )

  case let .toolExecution(tool) where verbosity == .compact:
    let phase = tool.phase.rawValue.uppercased()
    let text = "\(phase) \(tool.toolName)\n\(tool.arguments.prettyPrinted())"
    return AnyView(
      MessageBubble(role: "tool", title: "Tool Execution", text: text, isCompact: true)
        .padding(.horizontal),
    )

  case .toolExecution:
    return nil

  case let .compaction(compaction) where verbosity == .compact:
    let text = "Tokens before: \(compaction.tokensBefore)\n\n\(compaction.summary)"
    return AnyView(
      MessageBubble(role: "system", title: "Compaction", text: text, isCompact: true)
        .padding(.horizontal),
    )

  case .compaction:
    return nil

  case .header, .custom(customType: _, data: _), .unknown(type: _, payload: _):
    return nil
  }
}

private func roleLabel(_ message: WuhuPersistedMessage) -> String {
  switch message {
  case .user:
    "user"
  case .assistant:
    "assistant"
  case .toolResult:
    "tool"
  case .customMessage:
    "custom"
  case .unknown:
    "unknown"
  }
}

private func titleLabel(_ message: WuhuPersistedMessage, verbosity: SessionDetailFeature.Verbosity) -> String {
  switch message {
  case let .user(m):
    verbosity == .compact ? "User (\(m.user))" : "User"
  case let .assistant(m):
    verbosity == .compact ? "Assistant (\(m.provider.rawValue) · \(m.model))" : "Assistant"
  case let .toolResult(m):
    verbosity == .compact ? "Tool Result (\(m.toolName))" : "Tool"
  case let .customMessage(m):
    verbosity == .compact ? "Custom (\(m.customType))" : "Custom"
  case let .unknown(role, _):
    "Unknown (\(role))"
  }
}

private func messageText(_ message: WuhuPersistedMessage, verbosity: SessionDetailFeature.Verbosity) -> String {
  switch message {
  case let .user(m):
    return contentBlocksText(m.content, verbosity: verbosity)
  case let .assistant(m):
    var text = contentBlocksText(m.content, verbosity: verbosity)
    if verbosity == .compact, let usage = m.usage {
      text += "\n\nUsage: \(usage.totalTokens) tokens"
    }
    if let error = m.errorMessage, verbosity == .compact {
      text += "\n\nError: \(error)"
    }
    return text
  case let .toolResult(m):
    if verbosity == .minimal {
      return contentBlocksText(m.content, verbosity: .minimal)
    }
    return """
    Tool: \(m.toolName)
    isError: \(m.isError)

    \(contentBlocksText(m.content, verbosity: .compact))

    Details:
    \(m.details.prettyPrinted())
    """
  case let .customMessage(m):
    if verbosity == .minimal, m.display == false { return "" }
    var text = contentBlocksText(m.content, verbosity: verbosity)
    if verbosity == .compact, let details = m.details {
      text += "\n\nDetails:\n\(details.prettyPrinted())"
    }
    return text
  case let .unknown(_, payload):
    return payload.prettyPrinted()
  }
}

private func contentBlocksText(_ blocks: [WuhuContentBlock], verbosity: SessionDetailFeature.Verbosity) -> String {
  var parts: [String] = []
  for block in blocks {
    switch block {
    case let .text(text, _):
      parts.append(text)
    case let .toolCall(id, name, arguments) where verbosity == .compact:
      parts.append("Tool call: \(name) (\(id))\n\(arguments.prettyPrinted())")
    case let .reasoning(_, _, summary) where verbosity == .compact:
      if !summary.isEmpty {
        parts.append("Reasoning summary:\n" + summary.map { $0.prettyPrinted() }.joined(separator: "\n"))
      }
    default:
      break
    }
  }
  return parts.joined(separator: "\n\n")
}

private struct MessageBubble: View {
  let role: String
  let title: String
  let text: String
  let isCompact: Bool

  var body: some View {
    HStack {
      if role == "assistant" || role == "tool" {
        Spacer(minLength: 40)
      }

      VStack(alignment: .leading, spacing: 6) {
        Text(title)
          .font(.caption)
          .foregroundStyle(.secondary)

        Text(text.isEmpty ? " " : text)
          .font(isCompact ? .system(.caption, design: .monospaced) : .body)
          .textSelection(.enabled)
      }
      .padding(10)
      .background(backgroundColor)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

      if role == "user" || role == "custom" {
        Spacer(minLength: 40)
      }
    }
  }

  private var backgroundColor: Color {
    switch role {
    case "user":
      Color.blue.opacity(0.12)
    case "assistant":
      Color.green.opacity(0.12)
    case "tool":
      Color.orange.opacity(0.12)
    case "system":
      Color.gray.opacity(0.12)
    default:
      Color.secondary.opacity(0.08)
    }
  }
}

private extension JSONValue {
  func prettyPrinted() -> String {
    if let data = try? WuhuJSON.encoder.encode(self),
       let object = try? JSONSerialization.jsonObject(with: data),
       let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
       let string = String(data: pretty, encoding: .utf8)
    {
      return string
    }
    if let data = try? WuhuJSON.encoder.encode(self),
       let string = String(data: data, encoding: .utf8)
    {
      return string
    }
    return "\(self)"
  }
}
