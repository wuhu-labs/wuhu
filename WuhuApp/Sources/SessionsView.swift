import ComposableArchitecture
import SwiftUI
import WuhuAPI

struct SessionsView: View {
  let store: StoreOf<SessionsFeature>

  var body: some View {
    NavigationStackStore(
      store.scope(state: \.path, action: \.path),
    ) {
      List {
        if let error = store.error {
          Section {
            Text(error)
              .foregroundStyle(.red)
          }
        }

        Section {
          ForEach(store.sessions) { session in
            NavigationLink(state: SessionDetailFeature.State(
              sessionID: session.id,
              serverURL: store.serverURL,
              username: store.username,
            )) {
              SessionRowView(session: session)
            }
          }
        } header: {
          HStack {
            Text("Sessions")
            Spacer()
            if store.isLoading {
              ProgressView()
            }
          }
        }
      }
      .navigationTitle("Wuhu")
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          Button {
            store.send(.createButtonTapped)
          } label: {
            Image(systemName: "plus")
          }
          .disabled(store.serverURL == nil)
        }
      }
      .refreshable {
        await store.send(.refresh).finish()
      }
      .task {
        await store.send(.onAppear).finish()
      }
      .onDisappear {
        store.send(.onDisappear)
      }
      .sheet(store: store.scope(state: \.$createSession, action: \.createSession)) { store in
        CreateSessionView(store: store)
      }
    } destination: { store in
      SessionDetailView(store: store)
    }
  }
}

private struct SessionRowView: View {
  let session: WuhuSession

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(session.id)
        .font(.subheadline)
        .lineLimit(1)
        .truncationMode(.middle)

      HStack(spacing: 8) {
        Text("\(session.provider.rawValue) · \(session.model)")
        Text("· \(session.environment.name)")
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      Text(session.updatedAt.formatted(date: .abbreviated, time: .shortened))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
