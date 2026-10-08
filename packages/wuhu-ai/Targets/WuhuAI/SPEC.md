# WuhuAI backend notes

This file records backend-specific protocol behavior that WuhuAI intentionally
models. Keep it current when request/stream/replay semantics change.

## Responses API reasoning under `store: false`

WuhuAI uses the OpenAI Responses wire shape for both plain OpenAI GPT models and
ChatGPT/Codex models. Our policy is stateless requests: `store: false`.

For reasoning-capable Responses models, stateless replay requires encrypted
reasoning payloads. An output item id alone is not durable state: with
`store: false`, the backend does not retain the item behind that id for future
requests.

Request policy:

- When reasoning is enabled, request `include: ["reasoning.encrypted_content"]`.
- Request `reasoning.summary: "auto"` so summaries are available when the model
  supports them.
- Persist/replay native Responses reasoning only when it has non-empty
  `encrypted_content`.
- Drop reasoning items with no encrypted payload and no summary.
- Treat summary-only reasoning as display/cross-provider material, not as a
  native Responses reasoning item to replay with an id under `store: false`.
- Serialize unencrypted reasoning history as ordinary assistant text rather than
  as a native Responses reasoning item.

Observed Codex behavior:

- Codex can emit a `reasoning` output item with an `rs_...` id, `summary: []`,
  and no `encrypted_content` when the request omits
  `include: ["reasoning.encrypted_content"]`.
- This is a real final output item shape, not a parser artifact.
- Replaying that id-only item later under `store: false` is invalid because the
  backend has no stored item to resolve.

Stream merge policy:

- Treat `response.output_item.done` as the authoritative finalized item when it
  supplies a non-empty field.
- Merge defensively: if `done` omits or empties `encrypted_content` or summary,
  preserve the non-empty value already observed on earlier stream events for the
  same reasoning item.
- After merging, apply the persistence/replay policy above.

## Codex tools and legacy hosted search

Codex inference requests declare only the tools supplied by the caller. WuhuAI no longer automatically appends OpenAI's hosted `web_search`; Wuhu sessions use their ordinary `run_script` tool and `wuhu:web_search` capability instead. There is no feature flag or fallback that restores the hosted declaration. Explicit caller-supplied hosted tools remain supported for dedicated capability requests.

Hosted output parsing, provider-scoped transcript storage and native Responses replay remain supported. A same-provider `web_search_call` history item is replayed as its original payload, including its id, status, action, query and any exported source metadata, even when no hosted search tool is declared. Assistant text containing old citation markers is replayed unchanged; this change does not alter citation annotation parsing or the existing empty replay annotations. This does not recover provider-private page bodies that were never exported.

On October 7, 2026, tiny live calls to the subscription `/backend-api/codex/responses` accepted synthetic legacy `search`, `open_page` and `find_in_page` items without the hosted declaration, both with no tools and with only an ordinary function tool. Both successful streams emitted `OK` via `response.output_item.done` and finished with `response.completed`, `status: "completed"`, `error: null` and zero new hosted searches. The final response's `output` array was empty; the finalized output-item events carry the answer. These two successful calls are offline request/response fixtures in `Tests/IntegrationTests/Recordings/codex-legacy-search-*`.

## Media

- A `MediaResolver` may answer `.text` for media it cannot deliver in a form the request takes. Every dialect sends those words as a text part where the media would have gone, so the model knows something was there.
- Responses sends every `input_image` with `detail: "original"`, so the model sees the image at the size it was sent. `"auto"` lets older models shrink it to a preset. Fitting an image to a model's limits is the caller's job, done before resolving.

## Anthropic Messages URL

- An Anthropic-dialect endpoint's `baseURL` is the one the vendor publishes for Anthropic's SDKs, and requests go to `<baseURL>/v1/messages`: `https://api.anthropic.com`, `https://api.deepseek.com/anthropic`, `https://api.xiaomimimo.com/anthropic`.
- A `baseURL` whose path already ends in `/v1`, with or without a trailing slash, posts to `<baseURL>/messages`, so `https://api.anthropic.com/v1` and `…/anthropic/v1` keep working.

## Anthropic prompt caching

- `AnthropicEndpoint.promptCache` selects Anthropic's automatic caching: one top-level `cache_control` on the request body, whose breakpoint the API moves to the last cacheable block as the conversation grows. `.oneHour` writes `{"type": "ephemeral", "ttl": "1h"}`, `.fiveMinutes` writes `{"type": "ephemeral"}` at the 5-minute default TTL, and `.disabled`, the default, omits it. Which policy a product runs is the product's choice, never this package's.

## Usage and served model

`Usage.inputTokens` includes all input, cached or not, across Anthropic, Responses (including Codex), Chat Completions and Gemini. `uncachedInputTokens` subtracts `cacheReadTokens` and `cacheWriteTokens` without double counting and asserts that the remainder is nonnegative. `outputTokens` includes billed reasoning: Gemini adds `thoughtsTokenCount` to `candidatesTokenCount`, while other dialects already include reasoning in their output count. `reasoningTokens` is optional: absent means the provider did not report a separate count, not a reported zero. Anthropic leaves it absent. Existing stored usage with zero remains decodable.

`AssistantMessageMetadata.servedModel` is the API-reported model: Anthropic message model, Responses response model, Chat Completions chunk model or Gemini modelVersion. It is null when the API supplies none and never falls back to the configured model.

`InferenceEvent.usage` exposes each reported usage update and API-served model with the current partial message before completion; a later stream error does not erase those reports. The executor retains the last reported usage for failed or cancelled call accounting.

## Responses WebSocket transport

Responses endpoints can explicitly opt into `withWebSocket(session:attemptID:observer:)` without changing `ModelEndpoint.runInference`. The default remains HTTP/SSE. A `ResponsesWebSocketSession` is runtime-owned, memory-only and single-inference; callers must invalidate it on owner shutdown or lifecycle/config replacement. Endpoint rebuilds share that actor, not an endpoint-captured connection. URL, provider, model or handshake credential/header changes rotate the socket and clear the chain. Composition installs the WebSocket connector explicitly; there is no network/SSE fallback.

Each physical create is a text `response.create` with current instructions/properties and no `stream` or `background`. Inference explicitly selects 128 MiB transport limits, for frame, reassembled message, receive buffer and outbound message, with the finite parser queue independently bounded at the same size. A single provider event may carry a large opaque record, so inbound and parser budgets match the outbound budget. The serialized physical create (delta or corrective full create) is checked before dialing/sending; overflow is `InferenceError.requestTooLarge(limitBytes:)`, never a transport switch. Stock body/header hooks and sensitive marks are retained; only Codex receives `OpenAI-Beta: responses_websockets=2026-02-06`. Upgrade and Codex metadata headers use the existing per-call response-header receiver. Per-call observers receive numbered physical requests, raw inbound application messages before JSON parsing, and parsed JSON while that physical response is active. They are replaced on every inference, never captured by the persistent pump. Raw taps preserve UTF-8/binary bytes, including malformed messages, and are fenced across suspended callbacks. Idle/on-connect quota uses the separate session metadata receiver, never a finished attempt tap.

The socket pump feeds one finite event stream ending at the response terminal, not socket EOF. The existing SSE parser behavior is unchanged; WebSocket mode additionally supports interleaved function calls and refusal text. Successful terminals require a response id, usage and fully finished valid object arguments. Completed output-item events remain authoritative even if terminal `output` is empty. Supported max-token/content-filter incomplete terminals emit ordinary done/usage/stop-reason events but never establish a continuation candidate. Unknown incomplete, unsolicited cancellation, malformed/binary events and incoherent ids/arguments are typed failures. EOF/close before terminal is a transport failure. Local cancellation aborts and invalidates the generation, never sends a private interrupt extension.

A successful response is only a candidate. `acknowledge` requires the exact attempt, exact committed assistant content including phase, a bijective provider-to-committed tool-id map, and the full authoritative rendered baseline. No matching commit means no continuation. The next render must preserve every domain message, system/tools/property and canonical wire-input prefix. Media is reprojected at acknowledgement and on the next request; changed projections or unverifiable remote HTTP images force full context. Cached aliases translate only new `function_call_output` ids back to provider ids, never historical full context. Any mismatch sends full input with no previous id.

Before exposed output, a missing previous response permits one corrective full create on the same socket. A hard connection-limit event may instead reconnect and create in full, sharing the same one-recovery budget. Repeated misses/expiry and ambiguous midstream errors surface a typed failure for the caller's retry policy. Requests/errors accept Codex status/status_code and retry-header variants; context, auth, rate (including `usage_limit_reached`), transient, transport, incoming overflow and outbound-size failures are explicitly classified. Corrective creates are separate observer subattempts. Responses `malformed_model_message` errors on both WebSocket and HTTP/SSE streams map to `InferenceError.malformedModelMessage(message:reason:)`. The provider message and optional string `error.reason` are each bounded to 8192 characters; no tool-call repair or adapter retry occurs. Other HTTP/SSE fixtures and semantics are unchanged.

Offline contracts cover finite completion on a warm socket, acknowledged tool-id continuation over a Serve pair, unsafe/uncommitted baselines, parallel exact arguments, phase/header/tool/options/media invalidation, bounded recovery, reused per-call taps and quotas, typed refusal/error/incomplete/malformed/EOF behavior, cancellation, injected-clock idle timeout, credential rotation and one-inference isolation.

The WebSocket endpoint's optional `receiveQuota` callback is connection/session metadata: it receives `codex.rate_limits` during inference and while idle. It is replaced on each new inference, cleared on invalidation, and is generation-fenced. The per-attempt observer never receives idle events after its attempt ended. Consumers validate/project quota independently of token usage.
A validated terminal response is immutable: later normal close, EOF, I/O failure or protocol teardown can disable continuation, but cannot retract its queued completed result. Terminal identity lives with that physical response buffer, independently of connection state. Observer and metadata callback awaits are fenced by physical response-buffer identity as well as generation; a suspended callback from a previous turn cannot replace the reused socket's next active turn. Upgrade-header and request-observer awaits check cancellation and generation/inference identity before creating or sending further state. Callbacks are asynchronous and cancellation-cooperative; cancellation releases suspended stream-based callbacks and aborts transport without waiting for another provider event.

The provider capacity codes `websocket_backpressure`, `response_too_large` and `websocket_message_too_large` normalize to `InferenceError.capacityExceeded(code:message:status:)` before HTTP status or context-overflow heuristics, including when returned as 429 with Retry-After. The message is bounded to 8192 characters; code and supplied status are preserved. Responses WebSocket error/failed events, Responses SSE error/failed events and non-success HTTP bodies across dialects share this distinction. The adapter never retries or switches transports for these failures; the kernel owns bounded retry/compaction policy. Actual rate-limit codes and generic 429 responses keep their existing Retry-After behavior.

Responses SSE and WebSocket provider failures share status extraction: top-level numeric `status`, then `status_code`, then `error.status`, then `error.status_code`. This includes `response.failed`'s nested `response.error`. Capacity diagnostics preserve the same status on both transports.
