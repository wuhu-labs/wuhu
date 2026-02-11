import ComposableArchitecture
import SwiftUI
import WuhuAPI

struct CreateSessionView: View {
  let store: StoreOf<CreateSessionFeature>

  var body: some View {
    WithPerceptionTracking {
      NavigationStack {
        Form {
          if let error = store.error {
            Section {
              Text(error)
                .foregroundStyle(.red)
            }
          }

          Section {
            Picker(
              "Provider",
              selection: Binding(
                get: { store.provider },
                set: { store.send(.binding(.set(\.provider, $0))) },
              ),
            ) {
              Text("OpenAI").tag(WuhuProvider.openai)
              Text("Anthropic").tag(WuhuProvider.anthropic)
              Text("OpenAI Codex").tag(WuhuProvider.openaiCodex)
            }

            Picker(
              "Environment",
              selection: Binding(
                get: { store.environmentName },
                set: { store.send(.binding(.set(\.environmentName, $0))) },
              ),
            ) {
              ForEach(store.environments, id: \.name) { env in
                Text("\(env.name) (\(env.type))").tag(env.name)
              }
            }
            .disabled(store.isLoadingOptions)

            Picker(
              "Runner",
              selection: Binding(
                get: { store.runnerName },
                set: { store.send(.binding(.set(\.runnerName, $0))) },
              ),
            ) {
              Text("None").tag("")
              ForEach(store.runners, id: \.name) { runner in
                if runner.connected {
                  Text(runner.name).tag(runner.name)
                } else {
                  Text("\(runner.name) (disconnected)").tag(runner.name)
                }
              }
            }
            .disabled(store.isLoadingOptions)

            TextField(
              "Model (optional)",
              text: Binding(
                get: { store.model },
                set: { store.send(.binding(.set(\.model, $0))) },
              ),
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField(
              "System prompt (optional)",
              text: Binding(
                get: { store.systemPrompt },
                set: { store.send(.binding(.set(\.systemPrompt, $0))) },
              ),
              axis: .vertical,
            )
            .lineLimit(3, reservesSpace: true)
          } header: {
            HStack {
              Text("New Session")
              Spacer()
              if store.isLoadingOptions {
                ProgressView()
              }
            }
          }
        }
        .navigationTitle("Create Session")
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { store.send(.cancelTapped) }
          }
          ToolbarItem(placement: .confirmationAction) {
            Button("Create") { store.send(.createTapped) }
              .disabled(store.isCreating)
          }
        }
      }
      .task {
        await store.send(.onAppear).finish()
      }
    }
  }
}
