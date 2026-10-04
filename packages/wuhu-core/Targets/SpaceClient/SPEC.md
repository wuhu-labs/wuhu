# SpaceClient

`transcribe(_:contentType:language:provider:model:timestamps:diarize:)` posts private raw audio to `/v1/transcribe`. The existing first three parameters remain source-compatible; new optional parameters encode provider/model overrides, comma-separated words/segments timestamp requests, and a true/false diarization request as URL query items. The space's shared capability resolver is authoritative. The returned TranscriptionOutput retains text/provider/model and optional language/durationSeconds, with optional rich metadata added backward-compatibly. `transcriber()` remains the available/provider/model probe. General `api` calls carry web-search/image CLI JSON through the existing authenticated/group-scoped transport; no new credential API is exposed.
## Transport failures

Unknown server error codes remain transport failures rather than decoding as a known `ToolError`. `TransportFailure` exposes the HTTP status and raw error code when available, alongside its existing message. Domain adapters can classify retryable preparation and stale cursors without parsing the diagnostic sentence. Missing transport capabilities and invalid JSON do not invent a server error code.
