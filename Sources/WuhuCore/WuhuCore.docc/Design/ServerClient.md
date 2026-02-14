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
- `workspaces_path`: optional root directory for per-session workspaces (default: `~/.wuhu/workspaces`).
- `environments`: array of named environments.
  - `type`:
    - `local`: session working directory is `path` (resolved at session creation time).
    - `folder-template`: at session creation time, Wuhu copies the template folder at `path` into `workspaces_path/<session-id>` and uses that copied folder as the working directory.
      - Optional `startup_script` runs in the copied workspace after the copy completes.
  - `path`: filesystem path (meaning depends on `type`)

## HTTP API (v2)

The server exposes a minimal command/query/event API:

- **Queries (GET)**:
  - `GET /v2/sessions?limit=…` — list sessions
  - `GET /v2/sessions/:id` — session + transcript
    - Optional filters: `sinceCursor` (entry id), `sinceTime` (unix seconds)
- **Commands (POST)**:
  - `POST /v2/sessions` — create session (requires `environment`)
  - `POST /v2/sessions/:id/prompt` — enqueue prompt
    - Optional `user` field records the prompting user (see Client Identity below)
    - Returns immediately (`WuhuPromptDetachedResponse`); `detach` is accepted for backward compatibility but ignored
- **Streaming (GET + SSE)**:
  - `GET /v2/sessions/:id/follow` — stream session changes over SSE
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

Environment definitions live in a config file and can change at any time. To make sessions reproducible, Wuhu stores an **environment snapshot** in the database at session creation time:

- `WuhuSession.environment` is persisted alongside the session record.
- The working directory used for tools is `WuhuSession.cwd` (equal to `environment.path`).
  - For `local` environments, this is the resolved `path`.
  - For `folder-template` environments, this is the copied workspace path under `workspaces_path`.

This follows the principle: *session execution should not change retroactively when config changes*.

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

The client includes this identity in `POST /v2/sessions/:id/prompt` as `user`. The server persists it on `WuhuUserMessage.user`. If missing (or for historical rows), it defaults to `unknown_user`.

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
