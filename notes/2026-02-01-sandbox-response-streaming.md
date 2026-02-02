# Sandbox Response Streaming Design

Date: 2026-02-01

## Problem

How do we get response streaming from a sandbox back to our main app server
when:

- Main server has no public ingress (could be behind Tailnet)
- Sandboxes (Modal or Docker) can't reach main server directly

## Solution: Daemon as Durable Object

Instead of an external controller/relay service, make the **sandbox daemon
itself** the durable endpoint with a local SQLite buffer.

```
┌─────────────────────────────────────────────────────┐
│                    Sandbox                          │
│  ┌───────────────────────────────────────────────┐  │
│  │              Daemon (single process)          │  │
│  │  - SQLite buffer for response chunks          │  │
│  │  - Multiple WS clients for streaming (fan-out)│  │
│  │  - Serializes mutations (add msg, interrupt)  │  │
│  └───────────────────────────────────────────────┘  │
│                       ▲                             │
│                       │ Modal tunnel / Docker port  │
└───────────────────────┼─────────────────────────────┘
                        │
        ┌───────────────┼───────────────┐
        │               │               │
        ▼               ▼               ▼
   ┌─────────┐    ┌─────────┐    ┌─────────┐
   │ Web     │    │ Web     │    │ Main App│
   │ Client  │    │ Client  │    │ (log    │
   │ (live)  │    │ (live)  │    │ mover)  │
   └─────────┘    └─────────┘    └─────────┘
```

## Two Concerns, Cleanly Separated

| Concern             | Who              | Pattern                                                |
| ------------------- | ---------------- | ------------------------------------------------------ |
| Live streaming      | Web clients      | Connect directly to daemon, fan-out WS, lowest latency |
| Durable persistence | Main app replica | Redis lease, cursor-based pull, move to your DB        |

## Daemon Design

### SQLite Schema (minimal)

```sql
CREATE TABLE response_chunks (
  id INTEGER PRIMARY KEY,  -- cursor
  session_id TEXT NOT NULL,
  chunk BLOB NOT NULL,
  created_at INTEGER DEFAULT (unixepoch())
);

CREATE INDEX idx_session_cursor ON response_chunks(session_id, id);
```

### API

```
GET /sessions/{id}/stream?cursor=0
→ SSE or NDJSON of chunks where id > cursor

GET /sessions/{id}/status
→ { "state": "running" | "completed" | "failed", "last_chunk_id": 1234 }

POST /sessions/{id}/message
→ Add message to agent (serialized by daemon)

POST /sessions/{id}/interrupt
→ Interrupt agent (serialized by daemon)
```

### Properties

- **Single process, single writer** - mutations are trivially serialized, no
  distributed locking
- **Fan-out to multiple WS clients** - web clients connect directly for lowest
  latency
- **Cursor-based resume** - SQLite rowid is the cursor

## Main App Log Mover

Uses Redis lease to coordinate which replica owns persistence for a given
session:

```
# Replica tries to acquire ownership
SET sandbox:{id}:owner {replica_id} NX EX 30

# Replica heartbeats while connected
EXPIRE sandbox:{id}:owner 30

# Sweep job finds sandboxes with no owner, claims them
```

If a replica crashes:

1. Lease expires after 30s
2. Another replica claims it
3. New replica connects to daemon, resumes from cursor
4. No data lost (as long as daemon is still alive)

## Sandbox Death

**Policy: just give it up.**

- Sandbox dies → session is `failed` → move on
- The SQLite buffer is ephemeral by design, not a source of truth
- For 99% of cases (coding tasks), this is fine - just retry with another agent
- For administrative tasks, user should build their own idempotency/compensation

## Network Topology

```
┌─────────────────────────────────────────────────┐
│              Tailnet (private)                  │
│                                                 │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐  │
│  │ Main     │◀───│ Phone    │    │ Laptop   │  │
│  │ Server   │◀───│ (app)    │    │ (browser)│  │
│  │          │◀───┴──────────┴────┴──────────┘  │
│  └──────────┘                                  │
│       │                                        │
└───────┼────────────────────────────────────────┘
        │ outbound only
        ▼
   Push Services (APNs/FCM/Web)
   Sandboxes (Modal/Docker)
```

- Devices **can** reach main server (on Tailnet)
- Main server **can** reach push services and sandboxes (outbound)
- Nothing external can reach main server (no public ingress)

## Push Notification Dedup

Neither Web Push nor APNs dedupe across devices. "Seen on one, dismiss on
others" is your responsibility.

### Practical Solution: Delayed Push

```
Event happens (agent done, etc.)
         │
         ▼
    Wait 3-5 seconds
         │
         ▼
  Check: has any device polled/acked?
         │
    ┌────┴────┐
    │ Yes     │ No
    ▼         ▼
  Don't     Push to
  push      all devices
```

This works because devices are already connected to main server over Tailnet.
The push notification becomes a fallback/wake-up for idle devices, not the
primary delivery mechanism.

### Platform-Specific Collapse Keys

For repeated updates to the same task, use collapse keys to replace rather than
stack:

| Platform | Mechanism                                       |
| -------- | ----------------------------------------------- |
| Web Push | `Topic` header or `tag` in notification options |
| APNs     | `apns-collapse-id` header                       |
| FCM      | `collapse_key`                                  |
