# SpaceClient

`transcribe(_:contentType:language:provider:model:timestamps:diarize:)` posts private raw audio to `/v1/transcribe`. The existing first three parameters remain source-compatible; new optional parameters encode provider/model overrides, comma-separated words/segments timestamp requests, and a true/false diarization request as URL query items. The space's shared capability resolver is authoritative. The returned TranscriptionOutput retains text/provider/model and optional language/durationSeconds, with optional rich metadata added backward-compatibly. `transcriber()` remains the available/provider/model probe. General `api` calls carry web-search/image CLI JSON through the existing authenticated/group-scoped transport; no new credential API is exposed.
## Transport failures

Unknown server error codes remain transport failures rather than decoding as a known `ToolError`. `TransportFailure` exposes the HTTP status and raw error code when available, alongside its existing message. Domain adapters can classify retryable preparation and stale cursors without parsing the diagnostic sentence. Missing transport capabilities and invalid JSON do not invent a server error code.

## Filesystem observation

`ObserveRequest(mode: .glob(pattern), from: cursor, batch: true)` opts into whole-revision SSE frames by sending `batch=1`. A nil or false batch preserves the existing single-mutation stream; SQL requests do not send the batch flag. Consumers decode `RevisionEvents` and advance their cursor only after folding its event array.

## Exec sessions

`ExecSession.run(autoAcknowledge:failOnRemoteError:input:output:onEvent:onTermination:)` defaults to automatic acknowledgement and preserves the CLI's termination values. `onEvent` receives each machine exec event, including output truncation and timeout evidence. With `autoAcknowledge: false`, the consumer calls `acknowledgeExit()` only after its result is durable. `onTermination` runs while the caller transport is still maintained and must await settlement and acknowledgement before returning; returning from `run` closes that transport. `failOnRemoteError: true` terminates immediately with `.streamFailed(error.message)` on a failed event; its default false preserves CLI handling. Final typed `SpaceClient.DialRefusal` responses terminate the stream without redialing. A sever on a `cancelled` row redials once like the other terminal states when the machine can still settle it — the kill reached the machine (`ExecStatus.killDelivered`), the process had produced output, or the machine is attached — so a kill that lands after the row was cancelled still delivers the buffered tail and the exit, through a detach and reattach within the hub's grace; a second sever ends with `.cancelled`. An exec whose machine never got the kill and is away never ran there: `.cancelled` is immediate.

`input` is `.closed` (half-closed at once), `.stream(AsyncStream)` (half-closed on EOF) or `.caller`: the caller drives stdin with `sendStdin(_:)`, which waits for the machine's window, and `closeStdin()`. `acknowledge(through:)` and `kill()` forward to the caller leg; any of these made before `run` has dialed waits for it.

## Scripts

`runScript(_:)` posts a `ScriptRunInput` to `POST /v1/scripts` with a session credential and yields the run's `ScriptOutput`s as they arrive, closed by `end`. A sequence that finishes without `end` is a run that did not end (the server or the connection went away); dropping the sequence closes the connection, which cancels the run.

## Worker media

`media(_:)` reads a transcript media URL through the worker-only `/v1/media` route. Both blob and space-file references use this route; exec credentials are refused. Ordinary `file(_:)` reads remain subject to the caller’s current file access.
