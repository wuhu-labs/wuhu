# Stage 4.2: Daemon State Persistence

Daemon calls Core API after each turn to persist UI state.

## Prerequisites

- Stage 4.1 complete (Core state API exists)

## Daemon Changes

In `core/packages/sandbox-daemon/`:

### Turn Completion Hook

After each turn completes, daemon:
1. Collects all messages from the turn
2. Converts Pi agent events to UI-ready format
3. POSTs to Core `/sandboxes/:id/state`

### Message Conversion

Map Pi agent events to UI messages:

```typescript
interface UIMessage {
  cursor: number;
  role: "user" | "assistant" | "tool";
  content: string;
  toolName?: string;
  toolCallId?: string;
  turnIndex: number;
}

function convertTurnToMessages(turn: PiTurn, startCursor: number): UIMessage[] {
  // Convert turn events to flat message list
  // Assign sequential cursors starting from startCursor
}
```

### Cursor Tracking

Daemon maintains local cursor:
- Increments with each event
- Persisted to `/root/.wuhu/cursor.json` for crash recovery
- Sent with each state POST

### Core API URL

Daemon receives Core API base URL via `/init`:

```json
{
  "repo": "org/repo",
  "coreApiUrl": "http://core:3000"
}
```

## Error Handling

- Retry state POST on failure (3 attempts, exponential backoff)
- Log warning if persistence fails, don't block agent
- State persistence is best-effort for MVP

## Validates

Integration test:
1. Start sandbox with daemon
2. Send prompt, wait for turn to complete
3. Query Core `/sandboxes/:id/messages`
4. Assert messages match what daemon processed

## Deliverables

1. Turn completion hook in daemon
2. Message conversion logic
3. Core API client in daemon
4. Integration test
