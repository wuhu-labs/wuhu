import Foundation
import PiAI
@_spi(Testing) import PiAgent
import Testing

struct AgentLoopTests {
  @Test func emitsLifecycleEventsAndReturnsMessages() async throws {
    let context = AgentContext(systemPrompt: "You are helpful.", messages: [], tools: [])
    let config = AgentLoopConfig(
      model: .init(id: "mock", provider: .openai),
      requestOptions: .init(),
      streamFn: { model, _, _ in
        AsyncThrowingStream<AssistantMessageEvent, any Error> { continuation in
          Task {
            let message = AssistantMessage(
              provider: model.provider,
              model: model.id,
              content: [.text("Hi there!")],
              stopReason: .stop,
            )
            continuation.yield(.done(message: message))
            continuation.finish()
          }
        }
      },
    )

    let prompt: [Message] = [.user("Hello")]

    var sawAgentStart = false
    var sawAgentEnd = false
    var sawTurnStart = false
    var sawTurnEnd = false
    var endedMessages: [Message] = []

    let stream = agentLoop(prompts: prompt, context: context, config: config)
    for try await event in stream {
      switch event {
      case .agentStart:
        sawAgentStart = true
      case let .agentEnd(messages):
        sawAgentEnd = true
        endedMessages = messages
      case .turnStart:
        sawTurnStart = true
      case .turnEnd:
        sawTurnEnd = true
      default:
        break
      }
    }

    #expect(sawAgentStart)
    #expect(sawTurnStart)
    #expect(sawTurnEnd)
    #expect(sawAgentEnd)

    #expect(endedMessages.count == 2)
    if case .user = endedMessages[0] {} else { #expect(Bool(false)) }
    if case .assistant = endedMessages[1] {} else { #expect(Bool(false)) }
  }

  @Test func handlesToolCallsAndResults() async throws {
    actor Strings {
      var values: [String] = []
      func append(_ value: String) {
        values.append(value)
      }

      func snapshot() -> [String] {
        values
      }
    }

    let executed = Strings()

    let tool = AnyAgentTool(
      tool: Tool(
        name: "echo",
        description: "Echo tool",
        parameters: .object([
          "type": .string("object"),
          "properties": .object([
            "value": .object(["type": .string("string")]),
          ]),
          "required": .array([.string("value")]),
        ]),
      ),
      label: "Echo",
      execute: { _, args in
        let value = args.object?["value"]?.stringValue ?? ""
        await executed.append(value)
        return AgentToolResult(content: [.text("echoed: \(value)")], details: .object(["value": .string(value)]))
      },
    )

    let context = AgentContext(systemPrompt: "", messages: [], tools: [tool])

    let config = AgentLoopConfig(
      model: .init(id: "mock", provider: .openai),
      requestOptions: .init(),
      streamFn: { model, ctx, _ in
        let hasToolResult = ctx.messages.contains(where: { msg in
          if case .toolResult = msg { return true }
          return false
        })
        return AsyncThrowingStream<AssistantMessageEvent, any Error> { continuation in
          Task {
            if hasToolResult == false {
              let toolCall = ToolCall(id: "tool-1", name: "echo", arguments: .object(["value": .string("hello")]))
              let assistant = AssistantMessage(
                provider: model.provider,
                model: model.id,
                content: [.toolCall(toolCall)],
                stopReason: .toolUse,
              )
              continuation.yield(.done(message: assistant))
            } else {
              let assistant = AssistantMessage(
                provider: model.provider,
                model: model.id,
                content: [.text("done")],
                stopReason: .stop,
              )
              continuation.yield(.done(message: assistant))
            }
            continuation.finish()
          }
        }
      },
    )

    let stream = agentLoop(prompts: [.user("echo something")], context: context, config: config)
    var sawToolStart = false
    var sawToolEnd = false

    for try await event in stream {
      switch event {
      case .toolExecutionStart:
        sawToolStart = true
      case let .toolExecutionEnd(_, _, _, isError):
        sawToolEnd = true
        #expect(isError == false)
      default:
        break
      }
    }

    #expect(sawToolStart)
    #expect(sawToolEnd)
    #expect(await executed.snapshot() == ["hello"])
  }

  @Test func injectsSteeringMessagesAndSkipsRemainingTools() async throws {
    actor Strings {
      var values: [String] = []
      func append(_ value: String) {
        values.append(value)
      }

      func snapshot() -> [String] {
        values
      }

      func count() -> Int {
        values.count
      }
    }

    let executed = Strings()
    let queuedUserMessage: Message = .user("interrupt")

    let tool = AnyAgentTool(
      tool: Tool(
        name: "echo",
        description: "Echo tool",
        parameters: .object([
          "type": .string("object"),
          "properties": .object([
            "value": .object(["type": .string("string")]),
          ]),
          "required": .array([.string("value")]),
        ]),
      ),
      label: "Echo",
      execute: { _, args in
        let value = args.object?["value"]?.stringValue ?? ""
        await executed.append(value)
        return AgentToolResult(content: [.text("ok:\(value)")])
      },
    )

    let toolCalls: [ToolCall] = [
      .init(id: "tool-1", name: "echo", arguments: .object(["value": .string("first")])),
      .init(id: "tool-2", name: "echo", arguments: .object(["value": .string("second")])),
    ]

    actor Steering {
      var sent = false
      func nextMessages(executedCount: Int, message: Message) -> [Message] {
        guard executedCount == 1, sent == false else { return [] }
        sent = true
        return [message]
      }
    }
    let steering = Steering()

    let result = try await executeToolCallsForTesting(
      toolCalls: toolCalls,
      tools: [tool],
      getSteeringMessages: {
        let count = await executed.count()
        return await steering.nextMessages(executedCount: count, message: queuedUserMessage)
      },
    )

    #expect(await executed.snapshot() == ["first"])
    #expect(result.toolResults.count == 2)
    #expect(result.toolResults[0].isError == false)
    #expect(result.toolResults[1].isError == true)
    #expect(result.steeringMessages?.count == 1)

    let skippedText = result.toolResults[1].content.compactMap { block -> String? in
      if case let .text(part) = block { return part.text }
      return nil
    }.joined(separator: "\n")
    #expect(skippedText.contains("Skipped due to queued user message"))
  }

  @Test func continueThrowsOnEmptyContext() throws {
    let context = AgentContext(systemPrompt: "You are helpful.", messages: [], tools: [])
    let config = AgentLoopConfig(model: .init(id: "mock", provider: .openai))

    #expect(throws: AgentLoopContinueError.self) {
      _ = try agentLoopContinue(context: context, config: config)
    }
  }
}
