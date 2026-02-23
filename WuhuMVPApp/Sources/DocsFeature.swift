import ComposableArchitecture
import MarkdownUI
import SwiftUI

@Reducer
struct DocsFeature {
  @ObservableState
  struct State {
    var docs: IdentifiedArrayOf<MockDoc> = MockData.docs
    var selectedDocID: String?

    var selectedDoc: MockDoc? {
      guard let id = selectedDocID else { return nil }
      return docs[id: id]
    }
  }

  enum Action {
    case docSelected(String?)
  }

  var body: some ReducerOf<Self> {
    Reduce { state, action in
      switch action {
      case let .docSelected(id):
        state.selectedDocID = id
        return .none
      }
    }
  }
}

// MARK: - Docs List (content column)

struct DocsListView: View {
  @Bindable var store: StoreOf<DocsFeature>

  var body: some View {
    List(selection: $store.selectedDocID.sending(\.docSelected)) {
      ForEach(store.docs) { doc in
        VStack(alignment: .leading, spacing: 4) {
          Text(doc.title)
            .font(.callout)
            .fontWeight(.medium)
          HStack(spacing: 4) {
            ForEach(doc.tags, id: \.self) { tag in
              Text(tag)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.orange.opacity(0.1))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
            }
            Spacer()
            Text(doc.updatedAt, style: .relative)
              .font(.caption2)
              .foregroundStyle(.secondary)
          }
        }
        .padding(.vertical, 3)
        .tag(doc.id)
      }
    }
    .listStyle(.inset)
    .navigationTitle("Docs")
  }
}

// MARK: - Docs Detail (detail column)

struct DocsDetailView: View {
  let store: StoreOf<DocsFeature>

  var body: some View {
    if let doc = store.selectedDoc {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          HStack(spacing: 6) {
            ForEach(doc.tags, id: \.self) { tag in
              Text(tag)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.orange.opacity(0.12))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
            }
            Spacer()
            Text("Updated \(doc.updatedAt, style: .relative) ago")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Divider()
          Markdown(doc.markdownContent)
            .textSelection(.enabled)
        }
        .padding(24)
        .frame(maxWidth: 800)
      }
    } else {
      ContentUnavailableView(
        "No Document Selected",
        systemImage: "doc.text",
        description: Text("Select a document to view")
      )
    }
  }
}
