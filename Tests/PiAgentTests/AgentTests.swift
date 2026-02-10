import Foundation
import PiAgent
import PiAI
import Testing

struct AgentTests {
  @Test func createsAgentWithDefaultState() async {
    let agent = Agent(opts: .init())
    let state = await agent.state
    #expect(state.systemPrompt == "")
    #expect(state.messages.isEmpty)
    #expect(state.tools.isEmpty)
    #expect(state.isStreaming == false)
  }

  @Test func stateMutatorsUpdateState() async {
    let agent = Agent(opts: .init())
    await agent.setSystemPrompt("You are a helpful assistant.")
    await agent.setModel(.init(id: "mock", provider: .openai))

    let tool = AnyAgentTool(
      tool: .init(
        name: "noop",
        description: "No-op",
        parameters: .object(["type": .string("object")]),
      ),
      label: "No-op",
      execute: { _, _ in .init(content: [.text("ok")]) },
    )
    await agent.setTools([tool])
    await agent.replaceMessages([.user("Hello")])

    let state = await agent.state
    #expect(state.systemPrompt == "You are a helpful assistant.")
    #expect(state.model.id == "mock")
    #expect(state.tools.count == 1)
    #expect(state.messages.count == 1)
  }

  @Test func promptThrowsWhileStreaming() async throws {
    let agent = Agent(opts: .init(streamFn: { model, _, _ in
      AsyncThrowingStream<AssistantMessageEvent, any Error> { continuation in
        Task {
          let partial = AssistantMessage(provider: model.provider, model: model.id)
          continuation.yield(.start(partial: partial))
          try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
          let done = AssistantMessage(provider: model.provider, model: model.id, content: [.text("ok")])
          continuation.yield(.done(message: done))
          continuation.finish()
        }
      }
    }))

    let running = Task {
      try await agent.prompt("First")
    }

    try await Task.sleep(nanoseconds: 30_000_000) // 30ms
    let isStreaming = await agent.state.isStreaming
    #expect(isStreaming == true)

    do {
      try await agent.prompt("Second")
      #expect(Bool(false))
    } catch {
      #expect(Bool(true))
    }

    _ = try? await running.value
    await agent.waitForIdle()
    #expect(await agent.state.isStreaming == false)
  }
}
