import ComposableArchitecture
import SwiftUI

struct ServerFormView: View {
  let store: StoreOf<ServerFormFeature>

  var body: some View {
    WithPerceptionTracking {
      NavigationStack {
        Form {
          Section {
            TextField(
              "Name",
              text: Binding(
                get: { store.server.name },
                set: { store.send(.binding(.set(\.server.name, $0))) },
              ),
            )
            TextField(
              "URL",
              text: Binding(
                get: { store.server.urlString },
                set: { store.send(.binding(.set(\.server.urlString, $0))) },
              ),
            )
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
            .autocorrectionDisabled()

            TextField(
              "Username (optional)",
              text: Binding(
                get: { store.server.username ?? "" },
                set: { store.send(.binding(.set(\.server.username, $0.trimmedNonEmpty))) },
              ),
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          }

          if let error = store.error {
            Section {
              Text(error)
                .foregroundStyle(.red)
            }
          }
        }
        .navigationTitle(store.mode == .add ? "Add Server" : "Edit Server")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { store.send(.cancelTapped) }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Save") { store.send(.saveTapped) }
          }
        }
      }
    }
  }
}
