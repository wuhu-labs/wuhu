# Session Contracts (Queues + Subscription)

This article describes the *target* “meaning boundary” for sessions, expressed as transport-agnostic Swift protocols in `WuhuCore/Contracts`.

The goal is to:

- keep the persisted session transcript as a **single linear chain** (no insertion)
- allow **low-latency** external commands (enqueue/cancel) that do not wait for agent execution
- support a **single HTTP event stream** (SSE) that can deliver initial state + catch-up + live updates without gaps
- represent scheduling semantics explicitly (system urgent vs user steer vs user follow-up)

> Note: The current server implementation may not fully conform to these contracts yet. This document describes the intended shape to migrate toward.

## Transcript: `Entry` vs “Message Entry”

The transcript is a canonical ordered log of `Entry` values.

- Some entries are **message entries** and are eligible to become LLM input.
- Other entries are **non-message** (markers, diagnostics, tool surface, etc.) and exist for observability and UX.

See:

- `Entry` and `MessageEntry` in `Contracts/TranscriptContracts.swift`

**Invariant**

- The transcript remains append-only as a linear chain.
- Anything that must conceptually happen “before” something else must be materialized **earlier**, not inserted later.

This invariant is why queues exist.

## Input Lanes (Queues)

Wuhu distinguishes three “input lanes” that can influence the next model request:

1. `systemUrgent` — runtime/system injections (for example async callbacks) that must be applied at the steer checkpoint
2. `steer` — user “urgent correction” that should be applied at the steer checkpoint
3. `followUp` — user “next turn” input that should be applied at the follow-up checkpoint

See:

- `SystemUrgentInput`, `UserQueueLane` in `Contracts/QueueContracts.swift`

### Cancelability

- `steer` and `followUp` are cancelable by the client (enqueue/cancel).
- `systemUrgent` is not cancelable (no “撤回”).

This is modeled with distinct pending item and journal types.

### Ordering at the steer checkpoint

When a steer checkpoint occurs, the session actor drains lanes in this order:

1. `systemUrgent` (FIFO)
2. `steer` (FIFO)

The rationale is to avoid a total-ordering scheme between system and user lanes, while still making cross-lane ordering deterministic.

## Checkpoints (PiAgent as Canonical)

Queue items are not inserted into the transcript arbitrarily. They are materialized at defined checkpoints that match PiAgent’s execution boundaries:

- **Steer checkpoint**: immediately before the next model request, including the “post-tools” request
- **Follow-up checkpoint**: when the current run reaches a point where the next model request represents a new turn (that is, not part of tool execution / tool-result handling)

Materialization is an internal action performed by the session actor, and it appends message entries into the transcript chain so the next LLM request sees them in context.

## Command API vs Store Journal

The public command surface is intentionally small:

- enqueue steer
- cancel steer
- enqueue follow-up
- cancel follow-up

See:

- `SessionCommanding` in `Contracts/SessionCommanding.swift`

Persistence and observability require a richer representation: a **journal** that includes internal state transitions (especially materialization).

- External intent (API): enqueue/cancel
- Durable facts (store): enqueued/canceled/**materialized**

See:

- `UserQueueJournalEntry`, `SystemUrgentQueueJournalEntry` in `Contracts/QueueContracts.swift`

This separation keeps “pop/materialize” as an internal action (session actor owned), while still making queue state and history observable.

## Subscription: Initial + Live (Single Stream)

The HTTP/UI model is “one event stream” that:

1. provides initial state + catch-up to a desired cursor (transcript and queues)
2. continues with live updates
3. does not miss updates that occur during the initial backfill window

The Swift contract expresses this as:

- `SessionSubscribing.subscribe(sessionID:backfill:) -> SessionSubscription`

where a `SessionSubscription` is:

- `initial: SessionInitialState` (settings/status + transcript pages + queue backfill)
- `events: AsyncThrowingStream<SessionEvent, Error>` (live updates)

See:

- `SessionBackfillRequest`, `SessionInitialState`, `SessionEvent`, `SessionSubscribing` in `Contracts/SessionSubscriptionContracts.swift`

### Backfill strategy (no gaps, no duplicates)

The expected implementation strategy is:

1. subscribe to in-process changes (buffer briefly)
2. backfill from the durable store (`after` / `since` cursors)
3. coalesce buffered changes (for example: keep last settings snapshot)
4. return `initial` and then yield the coalesced buffer into `events`, followed by live forwarding

This design avoids requiring “replay from version X” inside SSE itself, while still supporting “I already have state since …” style query params.

### Queue backfill forms

Each queue lane supports two initial-load modes:

- `.snapshot` (current pending list + a “now” cursor)
- `.since(cursor)` (journal entries since cursor + a “now” cursor)

For journal backfill, implementations may coalesce transient enqueue→materialize pairs that complete entirely within the initial window, since transmitting already-processed work as “pending” is not useful.

## Identity

Entries and queued messages carry an `Author`:

- `.system`
- `.participant(id, kind: .human | .bot)`
- `.unknown` (for missing clients / historical data)

See:

- `Author` in `Contracts/SessionIdentity.swift`

