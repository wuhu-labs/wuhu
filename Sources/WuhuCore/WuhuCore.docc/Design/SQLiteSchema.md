# SQLite Persistence Schema

WuhuCore persists sessions as an **append-only linear chain** of entries stored in SQLite (via GRDB).

This article describes the schema-level model and invariants. It is intended to be stable enough that
other modules (server, UI, client) can rely on it without having to read migrations.

## Tables

Wuhu persists agent sessions into two tables:

- `sessions`: one row per session, including immutable `headEntryID` and mutable `tailEntryID`
- `session_entries`: one row per entry/event/message across all sessions

Entries form a linked structure via `parentEntryID`. The entry with `parentEntryID = NULL` is the **session header**.

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

SQLite enforces this with a partial unique index:

- unique on `sessionID` where `parentEntryID IS NULL`

### 2) No forks within a session

Forking within a session would allow multiple children to share the same parent entry.

Wuhu intentionally disallows this in v1, and SQLite enforces it with:

- unique on `parentEntryID` where `parentEntryID IS NOT NULL`

This means each entry can have at most one child, so the session is always a single linear chain from head → tail.

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

- new entry types (via `custom` / `unknown`)
- “message entry” variants (via `custom_message` / `unknown`)

