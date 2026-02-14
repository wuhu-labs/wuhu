import ComposableArchitecture
import SwiftUI

struct ServerFormView: View {
  let store: StoreOf<ServerFormFeature>

  var body: some View {
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
          .wuhuTextInputAutocapitalizationNever()
          .wuhuKeyboardTypeURL()
          .wuhuAutocorrectionDisabled()

          TextField(
            "Username (optional)",
            text: Binding(
              get: { store.server.username ?? "" },
              set: { store.send(.binding(.set(\.server.username, $0.trimmedNonEmpty))) },
            ),
          )
          .wuhuTextInputAutocapitalizationNever()
          .wuhuAutocorrectionDisabled()
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
