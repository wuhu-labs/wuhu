# ``WuhuCore``

WuhuCore provides a persisted, agent-session log for Wuhu’s Swift pivot.

The core design goal is to preserve the **tree-shaped session entry model** used by Pi (JSONL sessions with `id` + `parentId`), but store it in **SQLite (GRDB)** instead of files.

This module intentionally supports only a **single linear chain** within a session (no forks). Forking is modeled as creating a **new session** that references a parent session.

## Overview

Wuhu persists agent sessions into two tables:

- `sessions`: one row per session, including immutable `headEntryID` and mutable `tailEntryID`
- `session_entries`: one row per entry/event/message across all sessions

Entries form a linked structure via `parentEntryID`. The entry with `parentEntryID = NULL` is the **session header**.

## SQLite Schema

### `sessions`

Logical fields (see `SQLiteSessionStore` migration):

- `id` (TEXT PRIMARY KEY): session id returned to the CLI
- `provider` (TEXT): `openai`, `anthropic`, `openai-codex`
- `model` (TEXT): model id
- `environmentName` (TEXT): environment name resolved at session creation
- `environmentType` (TEXT): currently `local`
- `environmentPath` (TEXT): resolved path for the environment (absolute for `local`)
- `cwd` (TEXT): working directory at session creation
- `parentSessionID` (TEXT, nullable): reserved for future “fork session” feature
- `createdAt` / `updatedAt` (DATETIME)
- `headEntryID` (INTEGER, nullable at the DB level, but treated as required in the model)
- `tailEntryID` (INTEGER, nullable at the DB level, but treated as required in the model)

**Why `headEntryID` and `tailEntryID` exist**

In a file-based JSONL tree, “find the leaf” is cheap because all candidates live in one file.
In SQLite, efficient appends require tracking the current leaf (`tailEntryID`) so each new entry can be written with:

1. `parentEntryID = sessions.tailEntryID`
2. update `sessions.tailEntryID = newEntryID`

### `session_entries`

Logical fields:

- `id` (INTEGER PRIMARY KEY AUTOINCREMENT): entry id, referenced by `sessions.headEntryID` / `tailEntryID`
- `sessionID` (TEXT, FK → `sessions.id`)
- `parentEntryID` (INTEGER, nullable, FK → `session_entries.id`)
- `type` (TEXT): redundant with the JSON payload, used for indexing/debugging
- `payload` (BLOB): JSON-encoded `WuhuEntryPayload`
- `createdAt` (DATETIME)

## Invariants (Enforced)

### 1) Exactly one header entry per session

The header is the only entry with `parentEntryID IS NULL`.

SQLite enforces this with a **partial unique index**:

- unique on `sessionID` where `parentEntryID IS NULL`

### 2) No forks within a session

Forking within a session would allow multiple children to share the same parent entry.

Wuhu intentionally disallows this in v1, and SQLite enforces it with:

- unique on `parentEntryID` where `parentEntryID IS NOT NULL`

This means each entry can have **at most one child**, so the session is always a single linear chain from head → tail.

## Entry Payloads

All entry payloads are stored as JSON and decoded into `WuhuEntryPayload`:

- `header`: `WuhuSessionHeader` (includes the session’s `systemPrompt`)
- `message`: `WuhuPersistedMessage` (user / assistant / tool result / custom message)
- `tool_execution`: `WuhuToolExecution` (start/end markers)
- `custom`: extension state (does not participate in LLM context)
- `unknown`: forward-compatible fallback

### Message payloads

`WuhuPersistedMessage` mirrors the important parts of PiAI message types but stays `Codable`:

- `user`
- `assistant`
- `tool_result`
- `custom_message` (reserved for extensions; participates in context like a user message)
- `unknown`

User messages persist an additional identity field:

- `WuhuUserMessage.user` (defaults to `unknown_user` for historical data / missing clients)

This deliberately leaves space for:

- “new entry” types (via `custom` / `unknown`)
- “message entry” variants (via `custom_message` / `unknown`)

## Concurrency Model

- `SQLiteSessionStore` is an `actor` that wraps a `GRDB.DatabaseQueue`.
- `WuhuService` is an `actor` that:
  - loads a transcript from SQLite
  - runs a `PiAgent.Agent` loop
  - persists finalized events back to SQLite as the agent runs

All public store APIs are `async` to compose naturally with Swift concurrency.

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
