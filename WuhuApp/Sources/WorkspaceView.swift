import ComposableArchitecture
import PiAI
import SwiftUI
import WuhuAPI

struct WorkspaceView: View {
  @Bindable var store: StoreOf<WorkspaceFeature>

  var body: some View {
    NavigationStackStore(
      store.scope(state: \.path, action: \.path),
    ) {
      VStack(spacing: 0) {
        Picker("Mode", selection: $store.viewMode) {
          ForEach(WorkspaceFeature.State.ViewMode.allCases, id: \.self) { mode in
            Text(mode.rawValue).tag(mode)
          }
        }
        .pickerStyle(.segmented)
        .padding([.horizontal, .top])

        if store.viewMode == .docs {
          docsList
        } else {
          issuesKanban
        }
      }
      .navigationTitle("Workspace")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          filterMenu
        }
      }
      .searchable(text: $store.searchText, placement: .navigationBarDrawer(displayMode: .always))
      .task { await store.send(.onAppear).finish() }
      .onDisappear { store.send(.onDisappear) }
    } destination: { store in
      WorkspaceDocDetailView(store: store)
    }
  }

  private var docsList: some View {
    List {
      if let error = store.error {
        Section {
          Text(error)
            .foregroundStyle(.red)
        }
      }

      Section {
        ForEach(filteredDocs) { doc in
          NavigationLink(
            state: WorkspaceDocDetailFeature.State(
              path: doc.path,
              serverURL: resolvedServerURL,
            ),
          ) {
            WorkspaceDocRow(doc: doc)
          }
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
          }
        }
      }
    }
    .refreshable { await store.send(.refresh).finish() }
  }

  private var issuesKanban: some View {
    ScrollView([.horizontal, .vertical]) {
      LazyHStack(alignment: .top, spacing: 16) {
        ForEach(issueStatuses, id: \.self) { status in
          let issues = issuesByStatus[status] ?? []
          VStack(alignment: .leading, spacing: 10) {
            HStack {
              Text(status)
                .font(.headline)
              Spacer()
              if store.isLoading {
                ProgressView()
              } else {
                Text("\(issues.count)")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }

            ForEach(issues) { issue in
              NavigationLink(
                state: WorkspaceDocDetailFeature.State(path: issue.path, serverURL: resolvedServerURL),
              ) {
                IssueCardView(doc: issue)
              }
              .buttonStyle(.plain)
            }

            Spacer(minLength: 0)
          }
          .padding(12)
          .frame(width: 320, alignment: .leading)
          .background(
            RoundedRectangle(cornerRadius: 12)
              .fill(Color.secondary.opacity(0.08)),
          )
        }
      }
      .padding()
    }
    .overlay(alignment: .topLeading) {
      if let error = store.error {
        Text(error)
          .foregroundStyle(.red)
          .padding()
      }
    }
    .refreshable { await store.send(.refresh).finish() }
  }

  private var filterMenu: some View {
    Menu {
      if store.filterKey != nil || store.filterValue != nil {
        Button("Clear Filter") {
          store.send(.clearFilter)
        }
      }

      let keys = availableFrontmatterKeys
      if keys.isEmpty {
        Text("No filters")
      } else {
        ForEach(keys, id: \.self) { key in
          Menu(key) {
            ForEach(availableValues(for: key), id: \.self) { value in
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

  private var resolvedServerURL: URL {
    store.serverURL ?? URL(string: "http://127.0.0.1:5530")!
  }

  private var filteredDocs: [WuhuWorkspaceDocSummary] {
    var docs = Array(store.docs)

    if store.viewMode == .issues {
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

  private var issuesByStatus: [String: [WuhuWorkspaceDocSummary]] {
    Dictionary(grouping: filteredDocs) { doc in
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

  private var availableFrontmatterKeys: [String] {
    let keys = store.docs.flatMap { Array($0.frontmatter.keys) }
    return Array(Set(keys)).sorted()
  }

  private func availableValues(for key: String) -> [String] {
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
}

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

private struct IssueCardView: View {
  let doc: WuhuWorkspaceDocSummary

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(doc.frontmatter["title"]?.stringValue ?? (doc.path as NSString).lastPathComponent)
        .font(.subheadline)
        .lineLimit(2)

      if let assignee = doc.frontmatter["assignee"]?.stringValue, !assignee.isEmpty {
        Text("Assignee: \(assignee)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Text(doc.path)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12)
        .fill(Color.secondary.opacity(0.10)),
    )
  }
}
