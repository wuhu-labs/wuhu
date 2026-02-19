# Agent Loop Task Hierarchy

Wuhu’s agent execution can take minutes to hours (tool calls, retries, large repos). It must **not** be tied to a single HTTP request task (for example an SSE stream) because clients routinely cancel those tasks when they leave a screen.

This design keeps the agentic loop alive while still respecting structured concurrency.

## High-Level Model

- The server process creates a single `WuhuService` actor for the lifetime of the daemon.
- `WuhuService.startAgentLoopManager()` starts long-lived **background listeners** (for example async-bash completion routing).
- Wuhu starts one long-lived **per-session actor** (`WuhuSessionRuntime`) per session (as needed).
- `WuhuSessionRuntime` owns a persistent `AgentLoop<WuhuSessionBehavior>` and acts as the session’s execution loop.
- `POST /v2/sessions/:id/prompt` should be modeled as a low-latency command that enqueues user input (steer or follow-up) without waiting for agent execution.
- `GET /v2/sessions/:id/follow` is the canonical streaming channel for UI/CLI.

For the target meaning boundary (queues + subscription), see the Session Contracts design article.

## Task Hierarchy

At runtime the hierarchy looks like:

- `WuhuService.startAgentLoopManager()`
  - background listener tasks (for example async-bash completion routing)

For each active session:

- `WuhuSessionRuntime(sessionID: …)`
  - a long-lived loop observation task (publishes `WuhuSessionStreamEvent`)
  - a per-session loop task (`AgentLoop.start()`)

The key property is that prompt execution is a **child of the server’s long-lived manager**, not the request handler task.

## Prompt Flow

When a prompt arrives:

1. The server enqueues the user input into the appropriate lane (steer or follow-up).
2. The per-session runtime materializes queued inputs into the transcript at defined checkpoints (interrupt vs turn boundary).
3. The long-running agent execution proceeds independently of any particular HTTP request.

Clients that want live output should follow the session and render `WuhuSessionStreamEvent` until an `idle` event is observed.

## Cancellation

- Cancelling a follow stream **must not** cancel the agent loop.
- Stopping a session (`POST /v2/sessions/:id/stop`) aborts the active agent execution and appends an “Execution stopped” entry.
