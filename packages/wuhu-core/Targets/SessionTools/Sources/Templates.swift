import SessionDomain
import SpaceCore

extension ToolExecutor {
  func templateRoster(_ session: SessionID) async throws -> ToolResultPayload {
    let listings = try await space.sessionTemplates(in: space.principal(of: session).group).map { template in
      TemplateListing(
        name: template.name,
        kind: template.kind?.rawValue,
        provider: template.params.provider,
        model: template.params.model,
        effort: template.params.effort,
        description: template.description,
      )
    }
    return .templates(.init(templates: listings))
  }
}
