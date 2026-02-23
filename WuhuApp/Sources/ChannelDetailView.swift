import ComposableArchitecture
import Foundation
import SwiftUI
import WuhuAPI
import WuhuCore

/// Chat-style view for channel sessions. Reuses SessionDetailFeature for state management
/// but renders messages in a chat layout with user/agent attribution and timestamps.
struct ChannelDetailView: View {
  @Bindable var store: StoreOf<SessionDetailFeature>

  var body: some View {
    VStack(spacing: 0) {
      chatMessages
      Divider()
      chatComposer
    }
    .navigationTitle(store.displayTitle)
    .wuhuNavigationBarTitleDisplayModeInline()
    .toolbar {
      ToolbarItem(placement: .automatic) {
        chatStatusIndicator
      }
      ToolbarItem(placement: .primaryAction) {
        let canStop = store.executionStatus == .running
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

  private var chatStatusIndicator: some View {
    HStack(spacing: 6) {
      if store.isSubscribing || store.isRetrying {
        ProgressView()
          .controlSize(.small)
      }

      if store.isRetrying {
        Text(String(format: "Retrying (%.0fs)", store.retryDelaySeconds))
          .font(.caption)
          .foregroundStyle(.orange)
      } else {
        HStack(spacing: 4) {
          Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
          Text(statusLabel)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var statusColor: Color {
    switch store.executionStatus {
    case .running: .green
    case .idle: .yellow
    case .stopped: .gray
    }
  }

  private var statusLabel: String {
    switch store.executionStatus {
    case .running: "Running"
    case .idle: "Idle"
    case .stopped: "Stopped"
    }
  }

  private var chatMessages: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(spacing: 12) {
          if let error = store.error {
            Text(error)
              .foregroundStyle(.red)
              .padding(.horizontal)
          }

          let items = WuhuSessionTranscriptFormatter(verbosity: .minimal).format(Array(store.transcript))
          ForEach(items) { item in
            ChatMessageRow(item: item)
              .id(item.id)
          }
        }
        .padding(.vertical, 12)
      }
      .onChange(of: store.transcript.last?.id) { _, lastID in
        guard let lastID else { return }
        let lastVisibleID =
          WuhuSessionTranscriptFormatter(verbosity: .minimal)
            .format(Array(store.transcript))
            .last?.id ?? "entry.\(lastID)"
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(lastVisibleID, anchor: .bottom)
        }
      }
    }
  }

  private var chatComposer: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField(
        "Type a message...",
        text: Binding(
          get: { store.draft },
          set: { store.send(.binding(.set(\.draft, $0))) },
        ),
        axis: .vertical,
      )
      .lineLimit(1 ... 6)
      .textFieldStyle(.roundedBorder)
      .wuhuTextInputAutocapitalizationSentences()
      .onSubmit {
        store.send(.sendTapped)
      }

      Button {
        store.send(.sendTapped)
      } label: {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 24))
      }
      .buttonStyle(.borderless)
      .disabled(store.isEnqueuing || store.isStopping || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .padding(.horizontal)
    .padding(.vertical, 10)
  }
}

// MARK: - Sheet (reused from SessionDetailView scope)

private struct SessionModelPickerSheet: View {
  let store: StoreOf<SessionDetailFeature>

  var body: some View {
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

// MARK: - Chat Message Row

private struct ChatMessageRow: View {
  let item: WuhuSessionDisplayItem

  var body: some View {
    switch item.role {
    case .meta:
      HStack {
        Spacer()
        Text(item.text)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Color.secondary.opacity(0.08))
          .clipShape(Capsule())
        Spacer()
      }
      .padding(.horizontal)

    case .tool:
      HStack {
        Spacer()
        Text(item.text)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .italic()
        Spacer()
      }
      .padding(.horizontal)

    case .user:
      HStack(alignment: .top) {
        Spacer(minLength: 60)
        VStack(alignment: .trailing, spacing: 4) {
          Text(item.title.replacingOccurrences(of: ":", with: ""))
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text(linkifySessionLinks(item.text))
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.blue.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
      }
      .padding(.horizontal)

    case .agent:
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Agent")
            .font(.caption2)
            .foregroundStyle(.secondary)
          Text(linkifySessionLinks(item.text))
            .font(.body)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        Spacer(minLength: 60)
      }
      .padding(.horizontal)

    case .system:
      HStack {
        Spacer()
        Text(item.text)
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 10)
          .padding(.vertical, 4)
          .background(Color.gray.opacity(0.10))
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        Spacer()
      }
      .padding(.horizontal)
    }
  }
}
