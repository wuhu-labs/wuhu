# Async Background Shell Tool

WUHU-0010 introduces two coding-agent tools:

- `async_bash`: starts a bash command in the background and returns immediately with a task id.
- `async_bash_status`: queries whether that task is running or finished (and returns PID + stdout/stderr log file paths).

## Design Goals

1. **Non-blocking tool call**: starting a long-running command should not block the agent loop.
2. **Durable logs**: stdout and stderr are redirected to separate files so the agent can inspect output later.
3. **Immediate completion signaling**: when a task finishes, Wuhu should append a completion message to the session transcript as soon as possible (even if the model is still streaming).
4. **Leave space for steering queues**: completion signaling should leave room for future “steer queue” designs without changing the async task plumbing.

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

`WuhuService` subscribes to the registry’s completion stream and, for tasks that belong to the service instance:

- appends a `custom_message` entry (displayed as a system message in UIs)
- content is a JSON object including: `type: "system_reminder"`, `event: "async_bash_finished"`, `id`, `started_at`, `ended_at`, `duration`, `exit_code`, `output`
- `output` is truncated using the same tail-truncation policy as `bash`, and references the stdout/stderr log files as the source of truth

### 4) Steering (future-friendly)

PiAgent supports steering queues, but async task completion notifications are currently persisted to the transcript only (no automatic mid-turn steering injection), so agents won’t mistakenly treat them as interactive user input.
