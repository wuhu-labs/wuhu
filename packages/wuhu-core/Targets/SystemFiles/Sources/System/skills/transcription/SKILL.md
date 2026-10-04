---
name: transcription
description: Transcribe private audio with configured OpenAI or Qwen, or a zero-setup Codex login; request timestamp/speaker metadata as hard requirements.
---

# Transcription

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

The same resolver governs the app/browser dictation endpoint `/v1/transcribe`, `wuhu transcribe`, and this function. `/capabilities.json` selects `transcription.active`; `provider` deliberately overrides it. Absent capability configuration uses a Codex login. An explicit broken configuration fails, never falls back. The tools/modules remain declared. `CapabilityError` carries `code/message/hint`; retry transient unavailable/rate-limit failures, explain authentication/region/entitlement failures, or choose a different configured provider deliberately. Do not install credentials into `wuhu:secret`.

CLI: `wuhu transcribe recording.m4a --provider qwen --timestamps words,segments --diarize --json`. Without `--json`, the CLI prints text; without a file it probes availability/provider/model. `--model` and `--language` are optional. Native/browser callers need no change and still receive `text` in the existing response shape.
