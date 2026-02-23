# Server/Client Split

Wuhu’s Swift pivot originally exposed its capabilities via a local CLI that talked directly to the database and LLM providers. Issue #13 reshapes that into a single `wuhu` binary with a long‑running HTTP server and a thin client.

## Goals

- Run Wuhu as a daemon (`wuhu server`) with a stable HTTP API.
- Keep the client (`wuhu client …`) “dumb”: it talks only to the server and never calls LLMs directly.
- Preserve message-level streaming for agent responses.
- Introduce **environments** as named, server-managed working directories.

## Configuration

The server reads a YAML config file:

- Default path: `~/.wuhu/server.yml`
- Command: `wuhu server --config <path>`

Current schema (subset):

- `llm.openai` / `llm.anthropic`: optional API keys (if omitted, the server falls back to environment variables).
- `databasePath`: optional SQLite path (defaults to `~/.wuhu/server.sqlite`).
- `llm_request_log_dir`: optional directory for request/response logs.
- `host` / `port`: HTTP bind address (defaults to `127.0.0.1:5530`).
- `runners`: optional list of runner names and WebSocket addresses.

## HTTP API (v1)

The server exposes a minimal command/query/event API:

- **Environment CRUD**:
  - `GET /v1/environments` — list environments
  - `POST /v1/environments` — create environment
  - `GET /v1/environments/:identifier` — fetch by UUID or unique name
  - `PATCH /v1/environments/:identifier` — update by UUID or unique name
  - `DELETE /v1/environments/:identifier` — delete by UUID or unique name
- **Queries (GET)**:
  - `GET /v1/sessions?limit=…` — list sessions
  - `GET /v1/sessions/:id` — session + transcript
    - Optional filters: `sinceCursor` (entry id), `sinceTime` (unix seconds)
- **Commands (POST)**:
  - `POST /v1/sessions` — create session (requires `environment`, a UUID or unique environment name)
  - `POST /v1/sessions/:id/enqueue?lane=…` — enqueue a user message (serialized per session)
    - `lane` is `steer` or `followUp`
    - Body is `QueuedUserMessage` (contracts)
    - Returns `QueueItemID` (queued item identifier)
- **Streaming (GET + SSE)**:
  - `GET /v1/sessions/:id/follow` — stream session changes over SSE
    - Optional filters: `sinceCursor`, `sinceTime`
    - Stop conditions: `stopAfterIdle=1`, `timeoutSeconds`

### Streaming (SSE)

Prompting is a command (`POST`), but its result is observed via a follow stream:

- Response content type: `text/event-stream`
- Events are encoded as JSON `WuhuSessionStreamEvent` payloads in `data:` frames.
- The client represents these events as an `AsyncThrowingStream`.

The follow endpoint uses the same SSE encoding, and includes:

- persisted updates (`entry_appended`, with entry id + timestamp)
- in-flight assistant progress (`assistant_text_delta`)

Clients that want streaming should keep a `follow` stream open (or open one immediately after prompting) and render events until the session transitions to `idle`.

## Environment Snapshots (Persistence Decision)

Canonical environment definitions are stored in SQLite and can be created/updated/deleted at runtime via the HTTP API. To make sessions reproducible, Wuhu stores an **environment snapshot** in the database at session creation time:

- `WuhuSession.environment` is persisted alongside the session record.
- `WuhuSession.environmentID` stores the canonical environment id used to create the session.
- The working directory used for tools is `WuhuSession.cwd`:
  - For `local` environments, `cwd` is the resolved `environment.path`.
  - For `folder-template` environments, `cwd` is the copied workspace path under the environment’s configured workspaces root.

This follows the principle: *session execution should not change retroactively when the canonical environment definition changes*.

## Client Identity (Username)

The `wuhu client` reads an optional config file at `~/.wuhu/client.yml`:

```yaml
server: http://127.0.0.1:5530
username: alice@my-mac
```

Username resolution order:

1. `wuhu client … --username …`
2. `WUHU_USERNAME`
3. `~/.wuhu/client.yml` `username`
4. Default: `<osuser>@<hostname>`

The client includes this identity in `QueuedUserMessage.author` (typically `.participant(<id>, kind: .human)`). The server persists it on user message entries; if missing (or for historical rows), it defaults to `unknown_user`.

## Group Chat Escalation (Server-side)

Sessions are associated with the **first user who prompts them** (not the user who created the session).

When a prompt arrives from a different user for the first time, the server:

1. Appends a “system reminder” message entry (`custom_message`, `customType=wuhu_group_chat_reminder_v1`) that still participates in LLM context as a `user` role message.
2. For every **user** message created *after* that reminder entry, the server prefixes the message content when rendering to the LLM:

```
[username]:

<original message>
```

Messages created before the reminder entry are not modified.

## Migration Note

Database schema changes use additive GRDB migrations. When testing locally, deleting the previous SQLite file is still fine, but production deployments should rely on migrations.
