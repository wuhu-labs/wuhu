# Server/Runner Split

This document describes how Wuhu supports **remote tool execution** by splitting the system into:

- **Client**: talks only to the main server (HTTP + SSE)
- **Server**: runs LLM inference and persists sessions to SQLite
- **Runner**: executes the coding-agent **tools** (filesystem + shell) on a remote machine

## Goals

- Keep a **single binary** (`wuhu`) that can run as `server`, `client`, or `runner`.
- Ensure **LLM inference happens only on the main server**.
- Support two runner deployment modes:
  - **Runner-as-server**: runner listens on `:5531`; server connects out using `server.yml`.
  - **Runner-as-client**: runner connects to the server using `wuhu runner --connect-to http://…:5530`.
- Maintain a **constant number of server↔runner connections** as sessions grow (per runner: one WebSocket connection).
- Track tool execution by **session id** and **tool call id** (not just “environment”).

## Config Files

After this split, Wuhu supports:

- `~/.wuhu/server.yml` (required for `wuhu server`)
- `~/.wuhu/runner.yml` (required for `wuhu runner`)
- `~/.wuhu/client.yml` (optional for `wuhu client`)

### `server.yml` (excerpt)

```yaml
llm:
  openai: "…"
  anthropic: "…"
environments:
  - name: wuhu-repo
    type: local
    path: /Users/selveskii/Developer/wuhu-swift
runners:
  - name: vps-in-la
    address: 1.2.3.4:5531
```

### `runner.yml` (excerpt)

```yaml
name: vps-in-la
connectTo: http://1.2.3.4:5530 # optional; if set, runner connects to server
listen:                        # used when connectTo is not set
  host: 0.0.0.0
  port: 5531
databasePath: ~/.wuhu/runner.sqlite
environments:
  - name: wuhu-repo
    type: local
    path: /home/ubuntu/wuhu-swift
```

### `client.yml` (optional)

```yaml
server: http://127.0.0.1:5530
```

## Server↔Runner Wire Protocol

Server and runner communicate over **WebSocket** using a small JSON protocol:

- Messages are `Codable` (`WuhuRunnerMessage` in `WuhuAPI`).
- Each request/response pair includes a correlation `id`.
- Tool execution messages include:
  - `sessionID` (which session this tool call belongs to)
  - `toolCallId` (which tool call within the agent loop)

This allows the server to multiplex multiple sessions over a **single WebSocket** per runner.

## Concurrency and Head-of-Line Blocking

Even with one WebSocket per runner, we avoid “tool calls for session A block session B” by:

- Keeping the WebSocket **read loop** independent from tool execution.
- Executing each tool request in its own task on the runner, and responding when it completes.
- Correlating responses by `id`, so multiple in-flight tool calls can complete out of order.

### Future: Large File Transfer (Not Implemented)

Large file transfer is intentionally **not handled** in the current design.

If/when needed, the intended approach is:

1. Use WebSocket only to exchange a short-lived **transfer token** + metadata.
2. Transfer file bytes over a **separate HTTP connection** using that token.

This prevents large payloads from monopolizing the WebSocket channel.

## Session Environment Persistence on the Runner

The server persists an immutable snapshot of the chosen environment into the server database.

For runner sessions, the runner also maintains a small SQLite database (`runner_sessions`) mapping:

- `sessionID` → environment snapshot (`name`, `type`, `path`)

This enables tool execution messages to contain only `sessionID` (no “pwd”/environment identifier required on the wire).

## Database Schema Reuse

Wuhu intentionally keeps **separate databases** for:

- the main server (sessions + transcripts)
- each runner (sessionID → environment snapshot)

This aligns with the “two migrations, shared models” approach:

- Shared `Codable` models live in `WuhuAPI`.
- Each component owns its own migrations and db file path.

