import ComposableArchitecture
import Foundation
import SwiftUI
import WuhuAPI
import WuhuCore

struct SessionDetailView: View {
  @Bindable var store: StoreOf<SessionDetailFeature>

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      transcript
      Divider()
      composer
    }
    .navigationTitle(store.displayTitle)
    .wuhuNavigationBarTitleDisplayModeInline()
    .toolbar {
      ToolbarItem(placement: .automatic) {
        statusIndicator
      }
      ToolbarItem(placement: .primaryAction) {
        let canStop = store.executionStatus == .running
        Button("Stop") {
          store.send(.stopTapped)
        }
        .disabled(!canStop || store.isStopping)
      }
      ToolbarItem(placement: .primaryAction) {
        Button("Skills") {
          store.send(.binding(.set(\.isShowingSkills, true)))
        }
        .disabled(store.skills.isEmpty)
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
    .sheet(
      isPresented: Binding(
        get: { store.isShowingSkills },
        set: { store.send(.binding(.set(\.isShowingSkills, $0))) },
      ),
    ) {
      SkillsSheet(skills: store.skills)
    }
    .alert(store: store.scope(state: \.$alert, action: \.alert))
    .task { await store.send(.onAppear).finish() }
    .onDisappear { store.send(.onDisappear) }
  }

  @ViewBuilder
  private var statusIndicator: some View {
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
      .frame(maxWidth: 260)

      Spacer()

      if let parentID = store.parentSessionID {
        Button {
          store.send(.parentSessionTapped)
        } label: {
          Label("Forked from \(String(parentID.prefix(8)))...", systemImage: "arrow.branch")
            .font(.caption)
        }
        .buttonStyle(.borderless)
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 8)
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
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
        }
        .padding(.vertical, 10)
      }
      .onChange(of: store.transcript.last?.id) { _, lastID in
        guard let lastID else { return }
        let lastVisibleID =
          WuhuSessionTranscriptFormatter(verbosity: store.verbosity)
            .format(Array(store.transcript))
            .last?.id ?? "entry.\(lastID)"
        withAnimation(.easeOut(duration: 0.2)) {
          proxy.scrollTo(lastVisibleID, anchor: .bottom)
        }
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

private struct SkillsSheet: View {
  let skills: [WuhuSkill]

  var body: some View {
    NavigationStack {
      List {
        ForEach(skills) { skill in
          VStack(alignment: .leading, spacing: 6) {
            Text(skill.name)
              .font(.headline)
            Text(skill.description)
              .font(.subheadline)
              .foregroundStyle(.secondary)
            Text(skill.filePath)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .padding(.vertical, 4)
        }
      }
      .navigationTitle("Skills")
    }
  }
}

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

struct TranscriptItemRow: View {
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
      CollapsibleToolRow(item: item)
        .padding(.horizontal)

    case .system, .user, .agent:
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
    case .user: "user"
    case .agent: "assistant"
    case .system: "system"
    case .tool: "tool"
    case .meta: "meta"
    }
  }
}

private struct CollapsibleToolRow: View {
  let item: WuhuSessionDisplayItem
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button {
        withAnimation(.easeInOut(duration: 0.15)) {
          isExpanded.toggle()
        }
      } label: {
        HStack(spacing: 6) {
          Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(width: 12)

          Text(summaryLine)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)

          Spacer()
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if isExpanded, !detailText.isEmpty {
        Text(detailText)
          .font(.system(.caption2, design: .monospaced))
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
          .padding(.leading, 18)
          .padding(.top, 4)
      }
    }
    .padding(.vertical, 2)
    .padding(.horizontal, 10)
    .background(Color.orange.opacity(0.06))
    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var summaryLine: String {
    let lines = item.text.split(separator: "\n", maxSplits: 1)
    return String(lines.first ?? "")
  }

  private var detailText: String {
    let lines = item.text.split(separator: "\n", maxSplits: 1)
    guard lines.count > 1 else { return "" }
    return String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

struct MessageBubble: View {
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

        Text(linkifySessionLinks(text.isEmpty ? " " : text))
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
    case "user": Color.blue.opacity(0.12)
    case "assistant": Color.green.opacity(0.12)
    case "tool": Color.orange.opacity(0.12)
    case "system": Color.gray.opacity(0.12)
    default: Color.secondary.opacity(0.08)
    }
  }
}

func linkifySessionLinks(_ text: String) -> AttributedString {
  var attributed = AttributedString(text)
  let pattern = #"session://[A-Za-z0-9-]+"#
  guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return attributed }

  let nsRange = NSRange(text.startIndex ..< text.endIndex, in: text)
  let matches = regex.matches(in: text, options: [], range: nsRange)

  for match in matches.reversed() {
    guard let range = Range(match.range, in: text) else { continue }
    guard let attrRange = Range(range, in: attributed) else { continue }
    let raw = String(text[range])
    guard let url = URL(string: raw) else { continue }
    attributed[attrRange].link = url
  }

  return attributed
}
