import ComposableArchitecture
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
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          let canStop =
            store.isSending ||
            store.inferredExecution.state == .executing ||
            (store.inProcessExecution?.activePromptCount ?? 0) > 0

          Button("Stop") {
            store.send(.stopTapped)
          }
          .disabled(!canStop || store.isStopping)
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Model") {
            store.send(.binding(.set(\.isShowingModelPicker, true)))
          }
        }
      }
      .sheet(
        isPresented: Binding(
          get: { store.isShowingModelPicker },
          set: { store.send(.binding(.set(\.isShowingModelPicker, $0))) },
        ),
      ) {
        SessionModelPickerSheet(store: store)
      }
      .alert(store: store.scope(state: \.$alert, action: \.alert))
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
        Text("Minimal").tag(WuhuSessionVerbosity.minimal)
        Text("Compact").tag(WuhuSessionVerbosity.compact)
        Text("Full").tag(WuhuSessionVerbosity.full)
      }
      .pickerStyle(.segmented)

      if store.isLoading {
        ProgressView()
      }

      if store.isSending || store.inferredExecution.state == .executing || (store.inProcessExecution?.activePromptCount ?? 0) > 0 {
        Text("Running")
          .font(.caption)
          .foregroundStyle(.secondary)
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

          let items = WuhuSessionTranscriptFormatter(verbosity: store.verbosity).format(Array(store.transcript))
          ForEach(items) { item in
            TranscriptItemRow(item: item, verbosity: store.verbosity)
              .id(item.id)
          }

          if !store.streamingAssistantText.isEmpty {
            TranscriptSeparator()
              .padding(.horizontal)
            MessageBubble(
              role: "assistant",
              title: "Agent (streaming):",
              text: store.streamingAssistantText,
              isCompact: false,
            )
            .padding(.horizontal)
            .id("streaming.agent")
          }
        }
        .padding(.vertical, 12)
      }
      .onChange(of: store.transcript.last?.id) { lastID in
        guard let lastID else { return }
        let lastVisibleID =
          WuhuSessionTranscriptFormatter(verbosity: store.verbosity)
            .format(Array(store.transcript))
            .last?.id ?? "entry.\(lastID)"
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(lastVisibleID, anchor: .bottom)
        }
      }
      .onChange(of: store.streamingAssistantText) { _ in
        guard !store.streamingAssistantText.isEmpty else { return }
        proxy.scrollTo("streaming.agent", anchor: .bottom)
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
      .disabled(store.isSending || store.isStopping || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }
}

private struct SessionModelPickerSheet: View {
  let store: StoreOf<SessionDetailFeature>

  var body: some View {
    WithPerceptionTracking {
      NavigationStack {
        Form {
          if let status = store.modelUpdateStatus {
            Section {
              Text(status)
                .foregroundStyle(.secondary)
            }
          }

          if let error = store.error {
            Section {
              Text(error)
                .foregroundStyle(.red)
            }
          }

          Section {
            ModelSelectionFields(
              provider: Binding(
                get: { store.provider },
                set: { store.send(.binding(.set(\.provider, $0))) },
              ),
              modelSelection: Binding(
                get: { store.modelSelection },
                set: { store.send(.binding(.set(\.modelSelection, $0))) },
              ),
              customModel: Binding(
                get: { store.customModel },
                set: { store.send(.binding(.set(\.customModel, $0))) },
              ),
              reasoningEffort: Binding(
                get: { store.reasoningEffort },
                set: { store.send(.binding(.set(\.reasoningEffort, $0))) },
              ),
            )
          } header: {
            Text("Model")
          }

          Section {
            Button("Apply") { store.send(.applyModelTapped) }
              .disabled(store.isUpdatingModel)
          }
        }
        .navigationTitle("Model")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Done") { store.send(.binding(.set(\.isShowingModelPicker, false))) }
          }
          if store.isUpdatingModel {
            ToolbarItem(placement: .confirmationAction) {
              ProgressView()
            }
          }
        }
      }
    }
  }
}

private struct TranscriptItemRow: View {
  let item: WuhuSessionDisplayItem
  let verbosity: WuhuSessionVerbosity

  var body: some View {
    switch item.role {
    case .meta:
      Text(item.text)
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal)

    case .tool:
      MessageBubble(
        role: "tool",
        title: item.title,
        text: item.text,
        isCompact: true,
      )
      .padding(.horizontal)

    case .system, .user, .agent:
      TranscriptSeparator()
        .padding(.horizontal)
      MessageBubble(
        role: bubbleRole,
        title: item.title,
        text: item.text,
        isCompact: verbosity == .compact,
      )
      .padding(.horizontal)
    }
  }

  private var bubbleRole: String {
    switch item.role {
    case .user:
      "user"
    case .agent:
      "assistant"
    case .system:
      "system"
    case .tool:
      "tool"
    case .meta:
      "meta"
    }
  }
}

private struct TranscriptSeparator: View {
  var body: some View {
    Text("-----")
      .font(.system(.caption2, design: .monospaced))
      .foregroundStyle(.secondary)
  }
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
