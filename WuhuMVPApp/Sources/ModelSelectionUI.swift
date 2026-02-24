import PiAI
import SwiftUI
import WuhuAPI

enum ModelSelectionUI {
  static let customModelSentinel = "__custom__"
}

struct ModelSelectionFields: View {
  @Binding var provider: WuhuProvider
  @Binding var modelSelection: String
  @Binding var customModel: String
  @Binding var reasoningEffort: ReasoningEffort?

  var body: some View {
    Picker("Provider", selection: $provider) {
      Text("OpenAI").tag(WuhuProvider.openai)
      Text("Anthropic").tag(WuhuProvider.anthropic)
      Text("OpenAI Codex").tag(WuhuProvider.openaiCodex)
    }

    Picker("Model", selection: $modelSelection) {
      Text("Server default").tag("")
      ForEach(WuhuModelCatalog.models(for: provider)) { option in
        Text(option.displayName).tag(option.id)
      }
      Text("Custom...").tag(ModelSelectionUI.customModelSentinel)
    }

    if modelSelection == ModelSelectionUI.customModelSentinel {
      TextField("Custom model id", text: $customModel)
    }

    let supportedEfforts = WuhuModelCatalog.supportedReasoningEfforts(
      provider: provider, modelID: resolvedModelID,
    )
    if !supportedEfforts.isEmpty {
      Picker("Reasoning effort", selection: $reasoningEffort) {
        Text("Default").tag(nil as ReasoningEffort?)
        ForEach(supportedEfforts, id: \.self) { effort in
          Text(effort.rawValue).tag(Optional(effort))
        }
      }
    }
  }

  var resolvedModelID: String? {
    switch modelSelection {
    case "":
      nil
    case ModelSelectionUI.customModelSentinel:
      customModel.trimmedNonEmpty
    default:
      modelSelection
    }
  }
}

extension String {
  var trimmedNonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
