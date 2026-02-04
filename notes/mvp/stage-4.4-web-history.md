# Stage 4.4: Web UI History + SSE Resume

Load persisted history and seamlessly resume SSE streaming.

## Prerequisites

- Stage 4.2 complete (state persists to DB)

## Flow

1. User navigates to `/sandboxes/:id`
2. React Router loader fetches messages from Core API
3. Page renders history immediately
4. Browser opens SSE connection with `cursor` param
5. New events append seamlessly, no gaps or duplicates

## Loader

In `web/packages/app/app/routes/sandboxes.$id.tsx`:

```typescript
export async function loader({ params }: LoaderFunctionArgs) {
  const [sandbox, messages] = await Promise.all([
    fetchSandbox(params.id),
    fetchMessages(params.id), // GET /api/sandboxes/:id/messages
  ]);

  return { sandbox, messages };
}
```

## SSE with Cursor

```typescript
function useSandboxStream(sandboxId: string, initialCursor: number) {
  useEffect(() => {
    const url = `/api/sandboxes/${sandboxId}/stream/coding?cursor=${initialCursor}`;
    const eventSource = new EventSource(url);

    eventSource.onmessage = (event) => {
      const envelope = JSON.parse(event.data);
      // Only process events with cursor > initialCursor
      dispatch({ type: "EVENT", payload: envelope });
    };

    return () => eventSource.close();
  }, [sandboxId, initialCursor]);
}
```

## UI State

Combine loaded history with live stream:

```typescript
const { sandbox, messages: initialMessages } = useLoaderData();
const [messages, dispatch] = useReducer(messageReducer, initialMessages);
const lastCursor = messages[messages.length - 1]?.cursor ?? 0;

useSandboxStream(sandbox.id, lastCursor);
```

## Edge Cases

### No History Yet
- Loader returns empty messages array
- SSE starts from cursor 0
- Normal flow

### Reconnection
- On SSE disconnect, get current cursor from state
- Reconnect with that cursor
- No duplicate messages (cursor filtering)

### Stale Tab
- User returns to tab after long time
- SSE may have disconnected
- Refresh loader data, then reconnect SSE

## Validates

E2E test:
1. Create sandbox, send prompt
2. Wait for turn to complete
3. Refresh page
4. Assert: history loads correctly
5. Send follow-up prompt
6. Assert: new messages append without duplicates
7. Simulate disconnect/reconnect
8. Assert: stream resumes from correct cursor

## Deliverables

1. Loader fetches messages from Core API
2. SSE hook accepts cursor parameter
3. Seamless history + live stream in UI
4. E2E test for full flow
