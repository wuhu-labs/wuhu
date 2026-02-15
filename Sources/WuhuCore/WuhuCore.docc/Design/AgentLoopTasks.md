# Agentic Loop Task Hierarchy

Wuhu’s agent execution can take minutes to hours (tool calls, retries, large repos). It must **not** be tied to a single HTTP request task (for example an SSE stream) because clients routinely cancel those tasks when they leave a screen.

This design keeps the agentic loop alive while still respecting structured concurrency.

## High-Level Model

- The server process creates a single `WuhuService` actor for the lifetime of the daemon.
- `WuhuService.startAgentLoopManager()` starts long-lived **background listeners** (for example async-bash completion routing).
- Wuhu starts one long-lived **per-session actor** (`WuhuSessionAgentActor`) per session (as needed).
- `WuhuSessionAgentActor` owns the persistent `PiAgent.Agent` and acts as the session’s execution loop.
- `POST /v2/sessions/:id/prompt` enqueues work to the per-session actor. If a prompt is already running, the request waits until it can become active (because the transcript is persisted as a single linear chain).
- `GET /v2/sessions/:id/follow` is the canonical streaming channel for UI/CLI.

## Task Hierarchy

At runtime the hierarchy looks like:

- `WuhuService.startAgentLoopManager()`
  - background listener tasks (for example async-bash completion routing)

For each active session:

- `WuhuSessionAgentActor(sessionID: …)`
  - a long-lived agent event consumer task (persists PiAgent events)
  - a prompt-queue task (serializes prompts)
    - a per-prompt execution task (`PiAgent.Agent.prompt(...)`)

The key property is that prompt execution is a **child of the server’s long-lived manager**, not the request handler task.

## Prompt Flow

When a prompt arrives:

1. The server appends any required repair/reminder entries to the transcript.
2. The server appends the user prompt entry.
3. The server schedules the long-running agent execution on the session loop.
4. The prompt request returns (`WuhuPromptDetachedResponse`). If the session is busy, this happens once the prompt becomes active and is appended.

Clients that want live output should follow the session and render `WuhuSessionStreamEvent` until an `idle` event is observed.

## Cancellation

- Cancelling a follow stream **must not** cancel the agent loop.
- Stopping a session (`POST /v2/sessions/:id/stop`) aborts the active agent execution and appends an “Execution stopped” entry.
