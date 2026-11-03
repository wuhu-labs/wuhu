import struct ModelProviders.ModelsDocument
import struct SessionDomain.ContextBudget
import struct SessionDomain.ImageLimits

extension ModelsDocument.Provider {
  public var images: ImageLimits {
    switch imageFamily {
    case .claude: .claude
    case .openAI: .openAI
    case nil:
      switch dialect {
      case .anthropic: .claude
      case .responses, .codex: .openAI
      }
    }
  }
}

extension ModelsDocument.Model {
  public func budget(images: ImageLimits) -> ContextBudget {
    ContextBudget(maxInput: maxInput, maxOutput: maxOutput, headroomOverride: headroomOverride, images: images)
  }
}
