# Async Background Shell Tool

WUHU-0010 introduces two coding-agent tools:

- `async_bash`: starts a bash command in the background and returns immediately with a task id.
- `async_bash_status`: queries whether that task is running or finished (and returns PID + stdout/stderr log file paths).

## Design Goals

1. **Non-blocking tool call**: starting a long-running command should not block the agent loop.
2. **Durable logs**: stdout and stderr are redirected to separate files so the agent can inspect output later.
3. **Immediate completion signaling**: when a task finishes, Wuhu should append a user-level JSON message to the session transcript as soon as possible (even if the model is still streaming).
4. **Leave space for steering queues**: completion signaling should integrate naturally with Wuhu’s interrupt-priority queue and agent loop checkpoints.

## Implementation Overview

### 1) Process tracking: `WuhuAsyncBashRegistry`

`WuhuAsyncBashRegistry` is an actor that:

- starts a `/bin/bash -lc …` process
- redirects `stdout` and `stderr` to separate log files in the system temp directory
- tracks task state (`running` / `finished`, PID, timestamps, exit code, timeout)
- publishes task-completion events via `subscribeCompletions()`

This registry is used by the tool implementations and can be shared across sessions within a single process.

### 2) Tool surface: `async_bash` and `async_bash_status`

The `async_bash` tool:

- calls `WuhuAsyncBashRegistry.start(…)`
- returns a JSON payload containing `id` + a human-readable `message`

The `async_bash_status` tool:

- calls `WuhuAsyncBashRegistry.status(id:)`
- returns a JSON payload with `state`, optional `pid`, and `stdout_file`/`stderr_file` paths (plus timestamps / exit code when finished)

### 3) Transcript insertion on completion: `WuhuService`

`WuhuService` starts a background `WuhuAsyncBashCompletionRouter`, which subscribes to the registry’s completion stream and, for tasks that belong to the service instance:

- appends a `message` entry whose LLM role is **user**
- content is a JSON object including: `id`, `started_at`, `ended_at`, `duration`, `exit_code`, `timed_out`, `stdout_file`, `stderr_file`, `output`
- `output` is truncated using the same tail-truncation policy as `bash`, and references the stdout/stderr log files as the source of truth

### 4) Steering (future-friendly)

Completion messages are enqueued onto the session’s interrupt-priority queue so they can be drained and appended at the next safe checkpoint in the agent loop (between inference/tool phases).
