import ComposableArchitecture
import SwiftUI

struct SettingsView: View {
  let store: StoreOf<SettingsFeature>

  var body: some View {
    WithPerceptionTracking {
      NavigationStack {
        Form {
          Section("Servers") {
            ForEach(store.servers) { server in
              Button {
                store.send(.selectServer(server.id))
              } label: {
                HStack {
                  VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                    Text(server.urlString)
                      .font(.caption)
                      .foregroundStyle(.secondary)
                    if let username = server.username?.trimmedNonEmpty {
                      Text("User: \(username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                  }
                  Spacer()
                  if store.selectedServerID == server.id {
                    Image(systemName: "checkmark")
                      .foregroundStyle(.tint)
                  }
                }
              }
              .contextMenu {
                Button("Edit") {
                  store.send(.editServerButtonTapped(server.id))
                }
              }
            }
            .onDelete { offsets in
              store.send(.deleteServers(offsets))
            }

            Button {
              store.send(.addServerButtonTapped)
            } label: {
              Label("Add Server", systemImage: "plus")
            }
          }

          Section("User") {
            TextField(
              "Default username",
              text: Binding(
                get: { store.username },
                set: { store.send(.binding(.set(\.username, $0))) },
              ),
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            Text("You can override this per server by editing the server.")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .navigationTitle("Settings")
      }
      .sheet(
        store: store.scope(state: \.$serverForm, action: \.serverForm),
      ) { store in
        ServerFormView(store: store)
      }
    }
  }
}
