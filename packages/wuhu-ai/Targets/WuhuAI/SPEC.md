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

## Media

- A `MediaResolver` may answer `.text` for media it cannot deliver in a form the request takes. Every dialect sends those words as a text part where the media would have gone, so the model knows something was there.
- Responses sends every `input_image` with `detail: "original"`, so the model sees the image at the size it was sent. `"auto"` lets older models shrink it to a preset. Fitting an image to a model's limits is the caller's job, done before resolving.

## Anthropic Messages URL

- An Anthropic-dialect endpoint's `baseURL` is the one the vendor publishes for Anthropic's SDKs, and requests go to `<baseURL>/v1/messages`: `https://api.anthropic.com`, `https://api.deepseek.com/anthropic`, `https://api.xiaomimimo.com/anthropic`.
- A `baseURL` whose path already ends in `/v1`, with or without a trailing slash, posts to `<baseURL>/messages`, so `https://api.anthropic.com/v1` and `…/anthropic/v1` keep working.

## Usage and served model

`Usage.inputTokens` includes all input, cached or not, across Anthropic, Responses (including Codex), Chat Completions and Gemini. `uncachedInputTokens` subtracts `cacheReadTokens` and `cacheWriteTokens` without double counting and asserts that the remainder is nonnegative. `outputTokens` includes billed reasoning: Gemini adds `thoughtsTokenCount` to `candidatesTokenCount`, while other dialects already include reasoning in their output count. `reasoningTokens` is optional: absent means the provider did not report a separate count, not a reported zero. Anthropic leaves it absent. Existing stored usage with zero remains decodable.

`AssistantMessageMetadata.servedModel` is the API-reported model: Anthropic message model, Responses response model, Chat Completions chunk model or Gemini modelVersion. It is null when the API supplies none and never falls back to the configured model.

`InferenceEvent.usage` exposes each reported usage update and API-served model with the current partial message before completion; a later stream error does not erase those reports. The executor retains the last reported usage for failed or cancelled call accounting.
