# Agentic Loop Task Hierarchy

Wuhu’s agent execution can take minutes to hours (tool calls, retries, large repos). It must **not** be tied to a single HTTP request task (for example an SSE stream) because clients routinely cancel those tasks when they leave a screen.

This design keeps the agentic loop alive while still respecting structured concurrency.

## High-Level Model

- The server process creates a single `WuhuService` actor for the lifetime of the daemon.
- `WuhuService` owns a long-lived **agent loop manager task**.
- Under that manager, Wuhu starts one long-lived **session loop task** per session (as needed).
- `POST /v2/sessions/:id/prompt` enqueues work to the session loop and returns immediately.
- `GET /v2/sessions/:id/follow` is the canonical streaming channel for UI/CLI.

## Task Hierarchy

At runtime the hierarchy looks like:

- `WuhuService.startAgentLoopManager()`
  - agent loop manager task
    - per-session loop task (`sessionID = …`)
      - structured child tasks created by the session loop (e.g. concurrent agent event consumption)

The key property is that prompt execution is a **child of the server’s long-lived manager**, not the request handler task.

## Prompt Flow

When a prompt arrives:

1. The server appends any required repair/reminder entries to the transcript.
2. The server appends the user prompt entry.
3. The server schedules the long-running agent execution on the session loop.
4. The prompt request returns immediately (`WuhuPromptDetachedResponse`).

Clients that want live output should follow the session and render `WuhuSessionStreamEvent` until an `idle` event is observed.

## Cancellation

- Cancelling a follow stream **must not** cancel the agent loop.
- Stopping a session (`POST /v2/sessions/:id/stop`) aborts the active agent execution and appends an “Execution stopped” entry.

