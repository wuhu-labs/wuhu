# Attaching / Following a Session

Wuhu supports “attach” / “follow” workflows where a client subscribes to **live session changes**:

- a coding agent’s in-flight progress (assistant text deltas)
- persisted transcript updates (new prompts, messages, tool executions, compactions)

This is implemented without external brokers: Wuhu is a single process with a single SQLite database, so it can use an in-process fanout.

## Cursor Model

Every persisted session entry has:

- a monotonically increasing SQLite `id` (`INTEGER PRIMARY KEY AUTOINCREMENT`)
- `createdAt` (unix timestamp)

The entry `id` is the **cursor**.

Both the `prompt` and `get-session` commands surface these cursors so coding agents can safely poll/attach using:

- `--since-cursor <id>` to request updates since the last observed entry
- `--since-time <time>` when time-based filtering is preferred

## HTTP API

### Non-follow (query)

- `GET /v2/sessions/:id?sinceCursor=…&sinceTime=…`

Returns `WuhuGetSessionResponse` where `transcript` is filtered by the optional cursor/time constraints.

### Follow (SSE)

- `GET /v2/sessions/:id/follow?sinceCursor=…&sinceTime=…&stopAfterIdle=1&timeoutSeconds=…`

Returns `text/event-stream` where each `data:` frame is a JSON-encoded `WuhuSessionStreamEvent`.

## Event Types

The event stream includes:

- `entry_appended` — a persisted `WuhuSessionEntry` (includes cursor + timestamp)
- `assistant_text_delta` — in-flight assistant progress (not persisted as individual DB rows)
- `idle` — the session transitioned from “running” → “idle”
- `done` — server closed the stream (stop condition or timeout)

## Stop Conditions

Follow mode supports stopping:

- when the session becomes idle (`stopAfterIdle=1`)
- after a wall-clock timeout (`timeoutSeconds`)

The CLI defaults to `stopAfterIdle` if no timeout is provided, which is convenient for coding agents that “attach to the current run and return when it’s done”.

## Race-Free Catch-up

To avoid missing events when switching from “query the DB” → “subscribe to live events”, the server:

1. subscribes to the live event fanout (buffering a small window)
2. reads the initial filtered entries from SQLite
3. forwards buffered/live events, skipping already-delivered cursors

This yields “tail -f”-like behavior without introducing a message queue.

