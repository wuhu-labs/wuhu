# wuhu-ai

**WuhuAI** — a unified Swift LLM client library built directly on top of `Fetch`.

Provides `ModelEndpoint` types with streaming inference support across multiple backends:

- **OpenAI** (Responses API)
- **OpenAI Codex** (Responses API, Codex-tuned)
- **Anthropic** (Messages API)
- OpenAI-compatible chat-completions providers, Gemini, and more

Backend-specific protocol notes live in [`Targets/WuhuAI/SPEC.md`](Targets/WuhuAI/SPEC.md).

## Usage

```swift
import Dependencies
import Fetch
import FetchURLSession
import WuhuAI

let endpoint = OpenAIGPTEndpoint(model: "gpt-5.4", apiKey: "sk-...")
let context = Context(messages: [
  .user(UserMessage(content: [.text(TextContent(text: "Say hello"))])),
])

let inference = try await withDependencies {
  $0.fetch = .urlSession()
} operation: {
  try await endpoint.infer(context: context)
}

print(inference.message)
print(inference.metadata)
```

For streaming UIs, use `stream(context:options:mediaResolver:)` instead:

```swift
let events = withDependencies {
  $0.fetch = .urlSession()
} operation: {
  endpoint.stream(context: context)
}

for try await event in events {
  switch event {
  case let .textDelta(_, delta, _):
    print(delta, terminator: "")
  case let .done(_, metadata):
    print("\nTokens: \(String(describing: metadata.usage))")
  default:
    break
  }
}
```

## Adding as a Dependency

```swift
.package(url: "https://github.com/wuhu-labs/wuhu-ai.git", branch: "main")
.package(url: "https://github.com/wuhu-labs/wuhu-fetch.git", from: "0.2.2")
.package(url: "https://github.com/pointfreeco/swift-dependencies", from: "1.12.0")
```

Then depend on `WuhuAI`, `Fetch`, `Dependencies`, plus whatever fetch transport you want to use:

```swift
.product(name: "WuhuAI", package: "wuhu-ai")
.product(name: "Fetch", package: "wuhu-fetch")
.product(name: "FetchURLSession", package: "wuhu-fetch")
.product(name: "Dependencies", package: "swift-dependencies")
```

## License

Apache 2.0 — see [LICENSE](LICENSE).
