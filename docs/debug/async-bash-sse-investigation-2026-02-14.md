# Async bash + SSE investigation (2026-02-14)

This note captures what I found by inspecting the live server SQLite DB at `~/.wuhu/wuhu-issue14.sqlite` without restarting the server.

## Sessions inspected

### `c058daa6-e55e-4fab-958e-37bf270caea0` (prefix `c058daa6`)

- `async_bash` was used to run:
  - `mkdir -p …; screen -dmS … codex exec …`
- Important: this command *returns quickly* because `screen -dmS …` detaches and exits. So the async task that Wuhu tracks is the **launch** command, not the long-running `codex exec` process inside the detached screen session.
- Evidence in transcript:
  - `tool_execution` `async_bash` start at entry `1153`
  - `tool_execution` `async_bash` end at entry `1154` with task id `4966e90b-1b6f-440f-901e-3d4d2c6ad6ec`
  - `tool_result` message for `async_bash` at entry `1155` (JSON: “Task started…”)
  - completion message at entry `1156` (role `user`, `user: "unknown_user"`) shows `duration ~0.03s` and `exit_code: 0`

So: the “task completion json didn’t show up” symptom is **not** present in the DB for this session; if it wasn’t visible in the UI, it’s likely an SSE/client rendering issue.

### `3c4d9e8e-39ad-4e59-9684-9b493aa9ae7d` (prefix `3c4d9e8e`)

This session was a more direct async behavior test (`async_bash("sleep 10")` etc.).

- `async_bash sleep 10` returned task id `c018f581-51ad-4ae7-b12a-b42302c0c1d4` (tool end entry `1194` + tool_result message entry `1195`).
- Completion message was appended as a **user** message from `unknown_user` at entry `1206`, and it is a JSON blob (duration/ended_at/output/etc).
- After that completion message arrived, the transcript contains multiple assistant messages (`1209`, `1210`, `1211`, `1212`) that read like the agent is responding to that completion JSON as if it were user input (“You’re just re-posting the completion event…”).

Hypothesis: the completion notification being persisted as `role=user` (and additionally steered into active executions) is causing the agent loop to treat task completions as fresh user turns, generating confusing extra assistant turns.

## Code hotspots

- Completion persistence + steering: `Sources/WuhuCore/WuhuService.swift` `handleAsyncBashCompletion(_:)`
  - Currently appends a message entry with `.message(.user(... user: unknown_user ...))`
  - Also calls `exec.agent.steer(.user(jsonText ...))` for active executions.
- Tool contract wording: `Sources/WuhuCore/CodingAgentTools.swift` describes completion notification as “may insert …”

## Likely fixes (to validate)

1) Persist completion as a system-ish reminder (not an ordinary “user said: {json}”), e.g. prefixing content with `system-reminder:` and/or storing as `custom_message` (UI shows as system), while still rendering into LLM context in a non-confusing way.
2) Stop steering completion notifications into active agent executions (or gate it) to avoid auto-generating unsolicited assistant turns.
3) Improve SSE robustness / auto-reconnect in the iOS app and/or add server SSE keep-alives; observed iOS error reported: “stream ended at an unexpected time”.

