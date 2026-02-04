# Stage 4.1: Database Schema + Core State API

Add Postgres tables for session/message storage and Core endpoints to persist state.

## Database Schema

New tables in `core/packages/server/src/schema.ts`:

### sessions

Links to sandbox, tracks cursor position.

```typescript
export const sessions = pgTable("sessions", {
  id: text("id").primaryKey(), // matches sandbox id
  sandboxId: text("sandbox_id").notNull().references(() => sandboxes.id),
  cursor: integer("cursor").notNull().default(0),
  createdAt: timestamp("created_at").notNull().defaultNow(),
  updatedAt: timestamp("updated_at").notNull().defaultNow(),
});
```

### messages

Stores UI-ready messages for display.

```typescript
export const messages = pgTable("messages", {
  id: serial("id").primaryKey(),
  sessionId: text("session_id").notNull().references(() => sessions.id),
  cursor: integer("cursor").notNull(), // position in stream
  role: text("role").notNull(), // "user" | "assistant" | "tool"
  content: text("content").notNull(),
  toolName: text("tool_name"), // for tool messages
  toolCallId: text("tool_call_id"), // for tool messages
  turnIndex: integer("turn_index").notNull(),
  createdAt: timestamp("created_at").notNull().defaultNow(),
});

// Index for efficient cursor-based queries
// CREATE INDEX messages_session_cursor ON messages(session_id, cursor);
```

## Core API Endpoints

### POST /sandboxes/:id/state

Daemon calls this after each turn to persist UI state.

Request:
```json
{
  "cursor": 42,
  "messages": [
    {
      "cursor": 40,
      "role": "user",
      "content": "fix the auth bug",
      "turnIndex": 1
    },
    {
      "cursor": 41,
      "role": "assistant",
      "content": "I'll fix the authentication issue...",
      "turnIndex": 1
    },
    {
      "cursor": 42,
      "role": "tool",
      "content": "{ \"path\": \"src/auth.ts\", \"diff\": \"...\" }",
      "toolName": "edit_file",
      "toolCallId": "call_abc123",
      "turnIndex": 1
    }
  ]
}
```

Response:
```json
{
  "ok": true,
  "cursor": 42
}
```

### GET /sandboxes/:id/messages

Fetch persisted messages for a session.

Query params:
- `cursor` (optional): Start from this cursor (exclusive)
- `limit` (optional): Max messages to return (default 100)

Response:
```json
{
  "messages": [...],
  "cursor": 42,
  "hasMore": false
}
```

## Implementation

1. Add schema to `core/packages/server/src/schema.ts`
2. Generate migration: `deno task db:generate`
3. Add state persistence functions in `core/packages/server/src/state.ts`
4. Add routes in `core/packages/server/main.ts`

## Validates

Unit tests for:
- Schema migrations run successfully
- `POST /state` inserts messages correctly
- `GET /messages` returns messages in cursor order
- Cursor-based pagination works
- Duplicate cursor handling (idempotent upsert)

## Deliverables

1. Schema changes + migration
2. State persistence functions with unit tests
3. Core API routes
