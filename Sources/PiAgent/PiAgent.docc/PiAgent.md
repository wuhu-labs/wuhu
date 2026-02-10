# ``PiAgent``

Minimal agent-loop primitives built on top of ``PiAI``.

## Overview

`PiAgent` provides:

- An agent loop (`agentLoop`, `agentLoopContinue`) that repeatedly calls an LLM and executes tool calls.
- A Swift Concurrency–native ``Agent`` actor that exposes an `AsyncSequence` of ``AgentEvent`` via ``Agent/events``.

This is intentionally small and terminal-friendly: no UI framework, no thread primitives, and no subscription callbacks.

## Basic usage

```swift
import PiAI
import PiAgent

let tool = AnyAgentTool(
  tool: Tool(
    name: "weather",
    description: "Get the weather for a city",
    parameters: .object([
      "type": .string("object"),
      "properties": .object([
        "city": .object(["type": .string("string")]),
      ]),
      "required": .array([.string("city")]),
    ])
  ),
  label: "Weather",
  execute: { _, args in
    let city = (args.object?["city"]?.stringValue) ?? "Unknown"
    return AgentToolResult(content: [.text("Sunny in \\(city)")])
  }
)

let agent = Agent(opts: .init(initialState: .init(
  systemPrompt: "You are a helpful assistant.",
  model: Model(id: "gpt-4.1-mini", provider: .openai),
  tools: [tool]
)))

Task {
  for await event in agent.events {
    print(event)
  }
}

try await agent.prompt("What's the weather in San Francisco?")
```
