import ComposableArchitecture
import PiAI
import SwiftUI
import WuhuAPI

// MARK: - Docs List View

struct DocsListView: View {
  @Bindable var store: StoreOf<WorkspaceFeature>
  @Binding var selection: String?

  var body: some View {
    List(selection: $selection) {
      if let error = store.error {
        Section {
          Text(error)
            .foregroundStyle(.red)
        }
      }

      Section {
        ForEach(filteredDocs) { doc in
          WorkspaceDocRow(doc: doc)
            .tag(doc.path)
        }
      } header: {
        HStack(spacing: 8) {
          Text("Docs")
          if let filterKey = store.filterKey, let filterValue = store.filterValue {
            Text("\(filterKey)=\(filterValue)")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()
          if store.isLoading {
            ProgressView()
              .controlSize(.small)
          }
        }
      }
    }
    .navigationTitle("Docs")
    .searchable(text: $store.searchText, placement: .sidebar)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        filterMenu
      }
    }
    .refreshable { await store.send(.refresh).finish() }
    .overlay {
      if filteredDocs.isEmpty, !store.isLoading, store.error == nil {
        ContentUnavailableView(
          "No Documents",
          systemImage: "doc.text",
          description: Text(store.serverURL == nil ? "Configure a server in Settings" : ""),
        )
      }
    }
  }

  private var filteredDocs: [WuhuWorkspaceDocSummary] {
    filterDocs(from: store, issuesOnly: false)
  }

  private var filterMenu: some View {
    Menu {
      if store.filterKey != nil || store.filterValue != nil {
        Button("Clear Filter") {
          store.send(.clearFilter)
        }
      }

      let keys = availableFrontmatterKeys(from: store)
      if keys.isEmpty {
        Text("No filters")
      } else {
        ForEach(keys, id: \.self) { key in
          Menu(key) {
            ForEach(availableValues(for: key, from: store), id: \.self) { value in
              Button(value) {
                store.send(.setFilter(key: key, value: value))
              }
            }
          }
        }
      }
    } label: {
      Image(systemName: "line.3.horizontal.decrease.circle")
    }
    .disabled(store.docs.isEmpty)
  }
}

// MARK: - Issues List View

struct IssuesListView: View {
  @Bindable var store: StoreOf<WorkspaceFeature>
  @Binding var selection: String?

  var body: some View {
    List(selection: $selection) {
      if let error = store.error {
        Section {
          Text(error)
            .foregroundStyle(.red)
        }
      }

      ForEach(issueStatuses, id: \.self) { status in
        let issues = issuesByStatus[status] ?? []
        Section("\(status) (\(issues.count))") {
          ForEach(issues) { issue in
            IssueCardRow(doc: issue)
              .tag(issue.path)
          }
        }
      }
    }
    .navigationTitle("Issues")
    .searchable(text: $store.searchText, placement: .sidebar)
    .toolbar {
      if store.isLoading {
        ToolbarItem(placement: .automatic) {
          ProgressView()
            .controlSize(.small)
        }
      }
    }
    .refreshable { await store.send(.refresh).finish() }
    .overlay {
      if issueDocs.isEmpty, !store.isLoading, store.error == nil {
        ContentUnavailableView(
          "No Issues",
          systemImage: "checklist",
          description: Text(store.serverURL == nil ? "Configure a server in Settings" : ""),
        )
      }
    }
  }

  private var issueDocs: [WuhuWorkspaceDocSummary] {
    filterDocs(from: store, issuesOnly: true)
  }

  private var issuesByStatus: [String: [WuhuWorkspaceDocSummary]] {
    Dictionary(grouping: issueDocs) { doc in
      doc.frontmatter["status"]?.stringValue ?? "unknown"
    }
  }

  private var issueStatuses: [String] {
    let keys = Set(issuesByStatus.keys)
    let preferred = ["open", "in-progress", "done"]
    var out: [String] = []
    for s in preferred where keys.contains(s) {
      out.append(s)
    }
    out.append(contentsOf: keys.subtracting(preferred).sorted())
    return out
  }
}

// MARK: - Shared Helpers

private func filterDocs(from store: StoreOf<WorkspaceFeature>, issuesOnly: Bool) -> [WuhuWorkspaceDocSummary] {
  var docs = Array(store.docs)

  if issuesOnly {
    docs = docs.filter { $0.path.hasPrefix("issues/") }
  }

  let query = store.searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  if !query.isEmpty {
    docs = docs.filter { doc in
      let title = doc.frontmatter["title"]?.stringValue ?? (doc.path as NSString).lastPathComponent
      return title.lowercased().contains(query) || doc.path.lowercased().contains(query)
    }
  }

  if let key = store.filterKey, let value = store.filterValue, !key.isEmpty, !value.isEmpty {
    docs = docs.filter { doc in
      guard let fmValue = doc.frontmatter[key] else { return false }
      return matchesFilterValue(fmValue, value: value)
    }
  }

  return docs.sorted(by: { $0.path < $1.path })
}

private func availableFrontmatterKeys(from store: StoreOf<WorkspaceFeature>) -> [String] {
  let keys = store.docs.flatMap { Array($0.frontmatter.keys) }
  return Array(Set(keys)).sorted()
}

private func availableValues(for key: String, from store: StoreOf<WorkspaceFeature>) -> [String] {
  let values = store.docs.compactMap { doc -> [String]? in
    guard let v = doc.frontmatter[key] else { return nil }
    return scalarStrings(v)
  }
  return Array(Set(values.flatMap(\.self))).sorted()
}

private func scalarStrings(_ value: JSONValue) -> [String] {
  switch value {
  case .null:
    []
  case let .bool(v):
    [v ? "true" : "false"]
  case let .number(v):
    [String(v)]
  case let .string(v):
    [v]
  case let .array(values):
    values.flatMap(scalarStrings)
  case .object:
    []
  }
}

private func matchesFilterValue(_ value: JSONValue, value expected: String) -> Bool {
  scalarStrings(value).contains(expected)
}

// MARK: - Row Views

private struct WorkspaceDocRow: View {
  let doc: WuhuWorkspaceDocSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(doc.frontmatter["title"]?.stringValue ?? (doc.path as NSString).lastPathComponent)
        .font(.subheadline)
        .lineLimit(1)

      HStack(spacing: 8) {
        Text(doc.path)
          .lineLimit(1)
          .truncationMode(.middle)
        if let status = doc.frontmatter["status"]?.stringValue, !status.isEmpty {
          Text("· \(status)")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}

private struct IssueCardRow: View {
  let doc: WuhuWorkspaceDocSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(doc.frontmatter["title"]?.stringValue ?? (doc.path as NSString).lastPathComponent)
        .font(.subheadline)
        .lineLimit(2)

      HStack(spacing: 6) {
        if let assignee = doc.frontmatter["assignee"]?.stringValue, !assignee.isEmpty {
          Text(assignee)
        }
        if let status = doc.frontmatter["status"]?.stringValue, !status.isEmpty {
          Text("· \(status)")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }
}
