# Sandbox Daemon TODO

This file tracks the next concrete steps for the sandbox daemon package.

## Protocol 0 / Pi integration

- Add a `main.ts` entrypoint that:
  - Reads basic config from env (e.g., port, workspace root).
  - Constructs a `PiAgentProvider` and `createSandboxDaemonApp`.
  - Starts an HTTP server (Deno `serve`) on the configured port.
- Decide how to wire credentials into the Pi process:
  - Map `SandboxDaemonCredentialsPayload` into environment variables for `pi`.
  - Avoid ever writing secrets into logs or the event stream.

## HTTP API surface

- Extend tests to cover:
  - `POST /credentials` (accepts payload, returns `{ ok: true }`).
  - `POST /init` (echoes repo summaries and validates payload shape).
- Implement basic validation / error handling:
  - Reject malformed JSON with clear 4xx errors.
  - Return 5xx on internal failures instead of throwing.

## Streaming behavior

- Extend `/stream` implementation to support live tail:
  - Keep the SSE connection open and stream new events as they are appended.
  - Add minimal backoff / heartbeat behavior for idle streams.
- Add tests for:
  - Resuming from a non-zero `cursor`.
  - Multiple subscribers receiving the same events.

## Git checkpoint mode

- Introduce a lightweight abstraction for git operations scoped to a repo:
  - Commit (add + commit with a message template).
  - Optional push to a remote.
- Wire checkpoint behavior to agent events:
  - On relevant agent events (e.g., `turn_end`), run checkpoint logic when `mode === "per-turn"`.
  - Emit `checkpoint_commit` events with branch and commit SHA.
- Add tests using temporary git repositories:
  - Verify commits are created.
  - Verify checkpoint events are appended to the event stream.

## JWT / auth

- Implement JWT validation for incoming HTTP requests:
  - Parse `Authorization: Bearer <token>`.
  - Validate signature, `exp`, and `scope`.
  - Enforce `scope: "control"` for POST endpoints; allow `"observer"` for `/stream`.
- Add tests with hard-coded HMAC secret:
  - Valid control token can call `/prompt`.
  - Observer token can only call `/stream`.
  - Missing/invalid tokens are rejected.

## Configuration & ergonomics

- Define a small config module for:
  - Port, bind address.
  - JWT secret / issuer.
  - Workspace root (for future repo cloning/checkpointing).
- Document how to run the daemon locally (README section):
  - Example `deno run -A packages/sandbox-daemon/main.ts`.
  - Example curl commands for `/prompt` and `/stream`.

