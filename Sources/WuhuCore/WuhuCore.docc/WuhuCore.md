# ``WuhuCore``

WuhuCore provides a persisted, agent-session log for Wuhu’s Swift pivot.

The core design goal is to preserve the **tree-shaped session entry model** used by Pi (JSONL sessions with `id` + `parentId`), but store it in **SQLite (GRDB)** instead of files.

This module intentionally supports only a **single linear chain** within a session (no forks). Forking is modeled as creating a **new session** that references a parent session.

## Overview

Wuhu persists agent sessions as an append-only linear chain of entries stored in SQLite (via GRDB).

The detailed persistence schema and invariants live in the SQLite Schema design article.

See: <doc:SQLiteSchema>

## Concurrency Model

- `SQLiteSessionStore` is an `actor` that wraps a `GRDB.DatabaseQueue`.
- `WuhuService` is an `actor` that:
  - owns an in-process live event hub (`WuhuLiveEventHub`)
  - starts long-lived background listeners (for example async-bash completion routing)
  - routes API calls to a per-session `WuhuSessionAgentActor`
- `WuhuSessionAgentActor` is a per-session `actor` that:
  - owns a persistent `PiAgent.Agent`
  - serializes prompts via an in-memory queue
  - persists agent events to SQLite as they occur

All public store APIs are `async` to compose naturally with Swift concurrency.

## Topics

### Contracts

All implementation in this project is LLM-generated. Contract documents and the types under `Contracts/` serve as the **carbon-silicon alignment basis** — the specification that keeps generated code honest.

- <doc:ContractSession>
- <doc:ContractAgenticLoop>

### Design

- <doc:SQLiteSchema>
- <doc:SessionFollow>
- <doc:AgentLoopTasks>
- <doc:AsyncBash>
- <doc:ContextFiles>
- <doc:ServerClient>
- <doc:ServerRunner>
- <doc:FolderTemplateEnvironment>

## CLI Integration

The `wuhu` executable runs in three modes:

- `wuhu server` starts the HTTP server (LLM inference + persistence).
- `wuhu client …` talks to a running server (HTTP + SSE).
- `wuhu runner` executes coding-agent tools for remote sessions (see the Server/Runner design doc).

## Future: Forking Sessions (Not Implemented)

Forking is expected to be implemented by:

1. Creating a **new** `sessions` row with `parentSessionID` pointing to the source session
2. Creating a new header entry
3. Copying or referencing the desired prefix of entries into the new session (implementation choice)

This keeps per-session chains linear while still supporting “branching” at the session level.
