---
name: ai-scripts
description: Use wuhu:ai — tool-free completion, capability probes, private image generation/editing and transcription.
script_exports: {"wuhu:ai":["CapabilityError","CompletionError","capability","complete","editImage","generateImage","transcribe"],"wuhu:web_search":["CapabilityError"]}
---

# AI scripts

## Completion

`complete(promptOrMessages, { model, schema? })` returns text without tools, billed to your session. Missing, unknown or unconfigured models throw typed `CompletionError` without fallback.

Import `complete` and `CompletionError` from `wuhu:ai`. Choose an explicitly configured `provider/model` from `wuhu://settings.localspace/models.json`.

## Capability discovery

`capability(kind)` probes `image | transcription | web_search` configuration without spending money or checking credentials. It returns `{ kind, provider, dialect, model, authentication: "not_checked", features: { edit, timestamps, diarize } }`, never credentials or account identity.

`CapabilityError` is exported here and re-exported by `wuhu:web_search`. It carries `code`, `message`, `hint`; codes are `provider_not_configured`, `provider_auth`, `provider_region`, `provider_entitlement`, `provider_rate_limited`, `unsupported_feature`, `invalid_argument`, `provider_unavailable`. Retry transient failures; explain setup/entitlement failures or deliberately select another configured provider. Credentials live in the native provider store, never script secrets.

`wuhu://settings.localspace/capabilities.json` selects each capability's active provider (`image.active`, `transcription.active`, `web_search.active`). A provider override is an explicit configured variant, not a key or URL. Absent configuration synthesizes Codex through an existing ChatGPT login; explicit missing/broken providers or keys never fall back. Probing checks configuration only, not credentials, quotas, region or entitlement. Capability tools and modules remain declared regardless of availability.

## Images

```js
import { generateImage, editImage } from 'wuhu:ai'
const generated = await generateImage('a lunar garden', { destination: '/art/garden.png' })
const edited = await editImage(['/art/garden.png'], 'make the sky blue', { destination: '/art/blue-garden.png' })
result({ generated, edited })
```

`generateImage(prompt, options)` and `editImage(images, prompt, options)` return `{ path, mimeType: 'image/png', bytes, width, height }`, not pixels/base64. Options are `{ destination, provider?, model?, quality?, size? }`. Sizes: `1024x1024`, `1536x1024`, `1024x1536`; default square. Quality: `draft`, `standard`, `fine`, `ultra`. Qwen maps these exactly to `z-image-turbo`, `qwen-image-3.0`, `qwen-image-3.0-pro`, `wan2.7-image-pro`. Draft cannot edit. Other providers expose draft/standard/fine; ultra fails honestly rather than pretending fine is ultra. Do not combine Qwen `model` and `quality` overrides. No masks, bboxes, strength, regional or streaming options in v1.

References must be private PNG paths in your group, a readable group's `wuhu://<group>.localspace/...`, or an authorized `machines://<name-or-id>/...` file. No public URL or caller staging. At most five references; Qwen 3.0 and dedicated editors accept three and at most 10 MiB per reference. Other references are at most 25 MiB. The server reads bytes and talks to the provider internally; provider result downloads never receive bearer credentials.

Outputs are create-only: an existing destination, system path or another session's home is refused before provider spending. Space writes are atomic create-only; machine writes retain the existing stat/write guards and claims within a script run, not a cross-process atomic guarantee. Up to four image calls in one script run concurrently. Cancellation is propagated and failed calls do not write. `generate_image` uses the same resolver and supports the same optional provider/model/quality/size fields.

Unsupported editing/tier requests use `unsupported_feature`.

CLI: `wuhu image 'a lunar garden' --destination ./garden.png [--provider qwen] [--quality standard]`; editing adds one or more `--image ./reference.png`. CLI local output is created exclusively and never overwritten. The CLI uploads bytes privately to the authenticated server; it does not publish references.

## Transcription

```js
import { transcribe } from 'wuhu:ai'
result(await transcribe('/audio/meeting.m4a', {
  provider: 'qwen',
  timestamps: ['words', 'segments'],
  diarize: true,
}))
```

`transcribe(audio, { provider?, model?, language?, timestamps?, diarize? })` reads a private path in your group, a readable group, or an authorized machine path. WAV, MP3, M4A/MP4 and WebM are accepted. MP4/M4A fragments require track/decode/sample timing; unestablishable duration is invalid_argument before provider I/O, with a re-encode hint. Input must be nonempty, at most 25 MiB and at most two hours. Readable container timing is required; convert malformed/unsupported containers rather than bypassing the bound. No public Wuhu URL, arbitrary remote input URL or user-managed staging is required or accepted. The provider-managed upload and best-effort deletion stay inside the adapter; cleanup failure/crashes can leave provider staging files.

Result: required `{ text, provider, model }`; optional `language`, `durationSeconds`, `segments`, `words`, `confidence`, `usage`. Segments and words have `text`, optional `start/end` (seconds), `speaker`, `confidence`. Unavailable metadata is omitted, never invented from request hints. Speaker annotations carry no accuracy guarantee.

`timestamps` may contain `words` and/or `segments`. Requested timestamps and `diarize: true` are hard requirements: unsupported chosen-model requests return `unsupported_feature` before upload, never degraded success or a hidden model switch. Codex returns bare text. OpenAI `whisper-1` supports timestamps, not diarization; `gpt-4o-transcribe-diarize` supports speakers and segment timestamps, not word timestamps. Qwen's exact default `qwen-audio-3.1-asr-flash-filetrans` supports sentences, words and diarization together (mono input for diarization). The older `qwen3-asr-flash-filetrans` does not support diarization.

The same resolver governs the app/browser dictation endpoint `/v1/transcribe`, `wuhu transcribe`, and this function.

CLI: `wuhu transcribe recording.m4a --provider qwen --timestamps words,segments --diarize --json`. Without `--json`, the CLI prints text; without a file it probes availability/provider/model. `--model` and `--language` are optional. Native/browser callers need no change and still receive `text` in the existing response shape.
