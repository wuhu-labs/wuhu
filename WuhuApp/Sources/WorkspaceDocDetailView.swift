import ComposableArchitecture
import PiAI
import SwiftUI
import WuhuAPI

struct WorkspaceDocDetailView: View {
  let store: StoreOf<WorkspaceDocDetailFeature>

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if store.isLoading {
          ProgressView()
        }

        if let error = store.error {
          Text(error)
            .foregroundStyle(.red)
        }

        if let doc = store.doc {
          let badges = frontmatterBadges(doc.frontmatter)
          if !badges.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
              ForEach(badges, id: \.0) { key, value in
                BadgeView(text: "\(key): \(value)")
              }
            }
          }

          MarkdownBodyView(markdown: doc.body)
        } else {
          Text(store.path)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .padding()
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .navigationTitle(title)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          store.send(.refresh)
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .disabled(store.isLoading)
      }
    }
    .task {
      await store.send(.onAppear).finish()
    }
  }

  private var title: String {
    if let t = store.doc?.frontmatter["title"]?.stringValue, !t.isEmpty { return t }
    return (store.path as NSString).lastPathComponent
  }

  private func frontmatterBadges(_ fm: [String: JSONValue]) -> [(String, String)] {
    fm
      .keys
      .sorted()
      .compactMap { key in
        guard let value = fm[key] else { return nil }
        guard let rendered = renderFrontmatterValue(value) else { return nil }
        guard !rendered.isEmpty else { return nil }
        return (key, rendered)
      }
  }

  private func renderFrontmatterValue(_ value: JSONValue) -> String? {
    switch value {
    case .null:
      nil
    case let .bool(v):
      v ? "true" : "false"
    case let .number(v):
      String(v)
    case let .string(v):
      v
    case let .array(values):
      let rendered = values.compactMap(renderFrontmatterValue).filter { !$0.isEmpty }
      return rendered.isEmpty ? nil : rendered.joined(separator: ", ")
    case .object:
      nil
    }
  }
}

private struct BadgeView: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.caption)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        RoundedRectangle(cornerRadius: 8)
          .fill(Color.secondary.opacity(0.12)),
      )
  }
}

private struct MarkdownBodyView: View {
  let markdown: String

  var body: some View {
    if let attr = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .full)) {
      Text(attr)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    } else {
      Text(markdown)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
  }
}
