import Foundation
import Testing
import WuhuCore

struct EnvironmentPersistenceTests {
  @Test func createSessionPersistsFolderTemplateMetadata() async throws {
    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let env = WuhuEnvironment(
      name: "template-env",
      type: .folderTemplate,
      path: "/tmp/workspaces/sess-1",
      templatePath: "/tmp/template",
      startupScript: "startup.sh",
    )

    let sessionID = UUID().uuidString.lowercased()
    _ = try await service.createSession(
      sessionID: sessionID,
      provider: .openai,
      model: "mock",
      systemPrompt: "You are helpful.",
      environment: env,
    )

    let fetched = try await service.getSession(id: sessionID)
    #expect(fetched.environment.type == .folderTemplate)
    #expect(fetched.environment.path == "/tmp/workspaces/sess-1")
    #expect(fetched.environment.templatePath == "/tmp/template")
    #expect(fetched.environment.startupScript == "startup.sh")
  }
}
