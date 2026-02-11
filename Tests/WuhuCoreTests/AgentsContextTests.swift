import Foundation
import Testing
import WuhuCore

struct AgentsContextTests {
  private func makeTempDir(prefix: String) throws -> String {
    let base = FileManager.default.temporaryDirectory
    let dir = base.appendingPathComponent("\(prefix)-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    return dir.path
  }

  private func textContent(_ message: Message) -> String {
    switch message {
    case let .user(u):
      u.content.compactMap { if case let .text(t) = $0 { return t.text }; return nil }.joined(separator: "\n")
    case let .assistant(a):
      a.content.compactMap { if case let .text(t) = $0 { return t.text }; return nil }.joined(separator: "\n")
    case let .toolResult(t):
      t.content.compactMap { if case let .text(x) = $0 { return x.text }; return nil }.joined(separator: "\n")
    }
  }

  @Test func promptStreamInjectsAgentsContextIntoSystemPromptButDoesNotPersistIt() async throws {
    let dir = try makeTempDir(prefix: "wuhu-agents")
    let agentsMdPath = URL(fileURLWithPath: dir).appendingPathComponent("AGENTS.md").path
    let agentsLocalPath = URL(fileURLWithPath: dir).appendingPathComponent("AGENTS.local.md").path

    let agentsMdContent = "# AGENTS.md\n\n- speak like yoda\n"
    let agentsLocalContent = "# AGENTS.local.md\n\n- local override\n"
    try agentsMdContent.write(toFile: agentsMdPath, atomically: true, encoding: .utf8)
    try agentsLocalContent.write(toFile: agentsLocalPath, atomically: true, encoding: .utf8)

    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      provider: .openai,
      model: "mock",
      systemPrompt: "Base prompt.",
      environment: .init(name: "test", type: .local, path: dir),
    )

    actor Capture {
      var systemPrompt: String?
      func set(_ s: String?) {
        systemPrompt = s
      }

      func get() -> String? {
        systemPrompt
      }
    }
    let capture = Capture()

    let stream = try await service.promptStream(
      sessionID: session.id,
      input: "hello",
      tools: [],
      streamFn: { model, ctx, _ in
        await capture.set(ctx.systemPrompt)
        return AsyncThrowingStream { continuation in
          Task {
            let assistant = AssistantMessage(
              provider: model.provider,
              model: model.id,
              content: [.text("ok")],
              stopReason: .stop,
            )
            continuation.yield(.done(message: assistant))
            continuation.finish()
          }
        }
      },
    )

    for try await _ in stream {}

    let sp = try #require(await capture.get())
    #expect(sp.contains("# Project Context"))
    #expect(sp.contains("## \(agentsMdPath)"))
    #expect(sp.contains("## \(agentsLocalPath)"))
    #expect(sp.contains("speak like yoda"))
    #expect(sp.contains("local override"))

    // Not persisted: header prompt unchanged and injected text not stored as messages.
    let transcript = try await service.getTranscript(sessionID: session.id)
    guard let headerEntry = transcript.first, case let .header(header) = headerEntry.payload else {
      #expect(Bool(false))
      return
    }
    #expect(header.systemPrompt == "Base prompt.")

    let combined = transcript.compactMap { entry -> String? in
      guard case let .message(m) = entry.payload else { return nil }
      guard let pi = m.toPiMessage() else { return nil }
      return textContent(pi)
    }.joined(separator: "\n")

    #expect(!combined.contains("speak like yoda"))
    #expect(!combined.contains("local override"))
  }

  @Test func agentsContextReloadsWhenFilesChange() async throws {
    let dir = try makeTempDir(prefix: "wuhu-agents-change")
    let agentsMdPath = URL(fileURLWithPath: dir).appendingPathComponent("AGENTS.md").path

    try "v1".write(toFile: agentsMdPath, atomically: true, encoding: .utf8)

    let store = try SQLiteSessionStore(path: ":memory:")
    let service = WuhuService(store: store)

    let session = try await service.createSession(
      provider: .openai,
      model: "mock",
      systemPrompt: "Base prompt.",
      environment: .init(name: "test", type: .local, path: dir),
    )

    actor Capture {
      var prompts: [String] = []
      func add(_ s: String?) {
        if let s { prompts.append(s) }
      }

      func all() -> [String] {
        prompts
      }
    }
    let capture = Capture()

    func runOnce() async throws {
      let stream = try await service.promptStream(
        sessionID: session.id,
        input: "hello",
        tools: [],
        streamFn: { model, ctx, _ in
          await capture.add(ctx.systemPrompt)
          return AsyncThrowingStream { continuation in
            Task {
              let assistant = AssistantMessage(
                provider: model.provider,
                model: model.id,
                content: [.text("ok")],
                stopReason: .stop,
              )
              continuation.yield(.done(message: assistant))
              continuation.finish()
            }
          }
        },
      )
      for try await _ in stream {}
    }

    try await runOnce()

    try "v2 (changed)".write(toFile: agentsMdPath, atomically: true, encoding: .utf8)
    try await runOnce()

    let prompts = await capture.all()
    #expect(prompts.count == 2)
    #expect(prompts[0].contains("v1"))
    #expect(prompts[1].contains("v2 (changed)"))
  }
}
