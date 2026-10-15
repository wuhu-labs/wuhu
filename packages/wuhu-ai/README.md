# wuhu-ai

**WuhuAI** — a unified Swift LLM client library built directly on top of `Fetch`.

Provides `ModelEndpoint` types with streaming inference support across multiple backends:

- **OpenAI** (Responses API)
- **OpenAI Codex** (Responses API, Codex-tuned; caller-supplied tools only, no automatic hosted web search)
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

let message = try await withDependencies {
  $0.fetch = .urlSession()
} operation: {
  try await endpoint.inference(context: context).collect()
}

print(message)
```

For streaming UIs, consume the inference’s `stream()` instead:

```swift
let events = withDependencies {
  $0.fetch = .urlSession()
} operation: {
  endpoint.inference(context: context).stream()
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

## Account-bound replay

Raw endpoints default `replayScope` to nil: reasoning signatures/encrypted records and hosted-tool payloads cannot replay, even to the same provider name. To preserve faithful replay, supply a verified, nonsecret binding identifier via `replayScope`, stable across same-account token refresh and replaced on account/credential or endpoint binding changes. `routeEpoch` retires WebSocket continuation and rotates GPT/Codex cache/thread identity on routing changes. Never use bearer tokens or personal account identifiers for either field.

WuhuAI carries thinking and never polices it: Anthropic thinking is sent with or without a replay scope, and an upstream's own refusal surfaces as its error. Unknown or foreign-scoped signed reasoning keeps only its readable summary, as text, never decoded opaque data; unsigned readable thinking travels on as plain thinking, except to a Claude model, which rejects a thinking block without a signature and gets it as text; hosted records become safe type/action digests. See [the replay contract](Targets/WuhuAI/SPEC.md#replay-scope-and-portable-requests) for tool-loop and cache-key requirements.

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
