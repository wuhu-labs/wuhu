# Server/Client Split

Wuhu’s Swift pivot originally exposed its capabilities via a local CLI that talked directly to the database and LLM providers. Issue #13 reshapes that into a single `wuhu` binary with a long‑running HTTP server and a thin client.

## Goals

- Run Wuhu as a daemon (`wuhu server`) with a stable HTTP API.
- Keep the client (`wuhu client …`) “dumb”: it talks only to the server and never calls LLMs directly.
- Preserve message-level streaming for agent responses.
- Introduce **environments** as named, server-configured working directories.

## Configuration

The server reads a YAML config file:

- Default path: `~/.wuhu/server.yml`
- Command: `wuhu server --config <path>`

Current schema (subset):

- `llm.openai` / `llm.anthropic`: optional API keys (if omitted, the server falls back to environment variables).
- `environments`: array of named environments.
  - `type`: currently only `local`
  - `path`: local filesystem path used as the session working directory

## HTTP API (v2)

The server exposes a minimal command/query/event API:

- **Queries (GET)**:
  - `GET /v2/sessions?limit=…` — list sessions
  - `GET /v2/sessions/:id` — session + transcript
    - Optional filters: `sinceCursor` (entry id), `sinceTime` (unix seconds)
- **Commands (POST)**:
  - `POST /v2/sessions` — create session (requires `environment`)
  - `POST /v2/sessions/:id/prompt` — append prompt
    - `detach=true` returns immediately (`WuhuPromptDetachedResponse`)
    - otherwise streams events over SSE
- **Streaming (GET + SSE)**:
  - `GET /v2/sessions/:id/follow` — stream session changes over SSE
    - Optional filters: `sinceCursor`, `sinceTime`
    - Stop conditions: `stopAfterIdle=1`, `timeoutSeconds`

### Streaming (SSE)

Prompting is a command (`POST`), but its result is an event stream:

- Response content type: `text/event-stream`
- Events are encoded as JSON `WuhuSessionStreamEvent` payloads in `data:` frames.
- The client represents these events as an `AsyncThrowingStream`.

This preserves the coding-agent loop’s “text delta” streaming and tool execution events without introducing WebSocket.

The follow endpoint uses the same SSE encoding, and includes:

- persisted updates (`entry_appended`, with entry id + timestamp)
- in-flight assistant progress (`assistant_text_delta`)

## Environment Snapshots (Persistence Decision)

Environment definitions live in a config file and can change at any time. To make sessions reproducible, Wuhu stores an **environment snapshot** in the database at session creation time:

- `WuhuSession.environment` is persisted alongside the session record.
- The working directory used for tools is `WuhuSession.cwd` (currently equal to `environment.path` for `local` environments).

This follows the principle: *session execution should not change retroactively when config changes*.

## Migration Note

This repo is not yet deployed, so database schema changes modify the initial migration in place. When testing locally, delete the previous SQLite file before running the server.
