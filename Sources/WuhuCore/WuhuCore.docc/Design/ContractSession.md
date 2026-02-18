# Session Contracts

Session contracts define the programming model for Wuhu sessions.

> Some contract types may not yet match the names used in this document. Where they diverge, this document describes the target.

## Programming Model

A Wuhu session is:

1. An **append-only transcript** — a linear log of entries.
2. **Input lanes** (queues) — through which parties submit messages to the session.
3. A **canonical machine** — the LLM agent that generates responses, tool calls, and drives execution.
4. A **command surface** — short-lived commands (enqueue, cancel) that return quickly with an ID. The response does not include the downstream impact of the command.
5. A **subscription surface** — `(state, Stream<patch>)` for observation.

Each session has a single **owner** that loads state from the durable store (SQLite) on demand, serves reads from memory after the initial load, and persists all durable mutations. Only streaming ephemera (partial LLM message deltas) skip persistence.

For the agent loop that drives the canonical machine, see <doc:ContractAgentLoop>.

## Transcript

The transcript is the canonical ordered log of ``Entry`` values. It is **append-only**: entries are never inserted, reordered, or mutated.

The same canonical log can be **projected** into different shapes for different consumers. Without compaction, the LLM context projection is a simple flat filter over message-eligible entries. With compaction, the projection becomes more involved — see the Compaction section below. The UI projection is yet another shape entirely.

- **LLM input context**: filter to message-eligible entries. When a compaction entry exists, start from the compaction summary and include only entries after the compaction boundary (see Compaction).
- **UI rendering**: show all entries (including those before compaction boundaries), reorder and group tool calls between human messages by type (read / write / exec), collapse diagnostics, visually indicate compaction boundaries.

Entry types:

- **Message entries** (``MessageEntry``): eligible for LLM context. Carry an author and content.
- **Non-message entries** (markers, tool surface, diagnostics): exist for observability and UX.

## Parties and the Canonical Machine

Each session has one **canonical machine** — the LLM that generates tool calls, assistant messages, and drives the agentic loop.

All other participants are **parties**. A party can be a human, another LLM, or a bot account. All messages — from parties and from system sources alike — use a uniform header format:

    minsheng <lambda@liu.ms> 26/2/17 14:56

    message goes here...

    system-reminder 26/2/17 14:57

    async task xxx has finished execution. use xxx tool to get more info

There is no special casing for single-party vs multi-party sessions. Every message carries a header from the start. The canonical machine learns the format in-context.

See: ``Author``, ``ParticipantID``, ``ParticipantKind``

## Input Lanes

Three input lanes can influence the next model request:

1. **`system`** — runtime injections (async bash callbacks, task notifications). Applied at the steer checkpoint. Not cancelable.
2. **`steer`** — urgent corrections from parties. Applied at the steer checkpoint. Cancelable.
3. **`followUp`** — next-turn input from parties. Applied at the follow-up checkpoint. Cancelable.

> **Terminology note**: "system" and "user" here refer to lane semantics, not LLM message roles. The mapping to provider-specific roles is a separate concern: OpenAI maps system-lane content to the `developer` role; Anthropic and most providers map both to `user`. The `system` role is reserved for top-of-context prompts and is never used for lane content.

### Cancelability

- `steer` and `followUp` support enqueue and cancel by the client.
- `system` is not cancelable — once enqueued, it will be materialized.

The system lane and user lanes have distinct pending item and journal types because they differ in nature: system items have a machine source (e.g., `asyncBashCallback`), while user items have a party author.

See: ``SystemUrgentInput``, ``UserQueueLane``, ``QueuedUserMessage``

> **Target**: rename ``SystemUrgentInput`` to `SystemInput` and `systemUrgent` to `system`.

## Checkpoints

Checkpoints are moments where queued inputs are **materialized** — written into the transcript so the next LLM request sees them in context. Checkpoints are defined relative to the previous LLM response:

- **Steer checkpoint**: the previous response contained tool calls and all tool results have been collected. The owner drains the **system** and **steer** lanes before the next inference call.
- **Follow-up checkpoint**: the previous response contained no tool calls — a turn of agent work is complete. The owner drains **system** and **steer** first; if those are empty, drains **follow-up**.

Lanes are drained **eagerly** at each checkpoint. If the accumulated input genuinely cannot fit in context even after compaction, the session errors explicitly rather than attempting staged draining.

### Cross-lane ordering

Items within a lane are ordered FIFO. Across lanes, items are ordered by **enqueue timestamp**. This avoids an arbitrary priority scheme between system and user lanes while keeping ordering deterministic.

## Command API

The public command surface is intentionally small. Commands return quickly with an ID; the downstream impact (materialization into the transcript) is observed via subscription.

- `enqueue(message, lane: .steer | .followUp)` → `QueueItemID`
- `cancel(id, lane: .steer | .followUp)`

The data types for steer and follow-up payloads are identical (``QueuedUserMessage``), differing only in which lane they target.

See: ``SessionCommanding``

## Materialization and Journal

**Materialize** means writing a queued item into the transcript. Materialization is an internal action performed by the session owner at checkpoints. A materialized item has been appended to the transcript, but may not yet have been sent to the LLM — for example, if the session is interrupted between materialization and the next inference call.

Persistence and observability require a richer representation than the command API: a **journal** that records the full lifecycle of each queued item:

- **External commands** (API): enqueue, cancel
- **Durable facts** (store): enqueued, canceled, **materialized**

Materialization links a queue item to its transcript entry via ``TranscriptEntryID``, making the queue-to-transcript flow fully traceable.

See: ``UserQueueJournalEntry``, ``SystemUrgentQueueJournalEntry``

## Subscription: State + Patch

The core observation primitive is `subscribe(since:)`, which returns a **stable patch** followed by a **stream of events**.

### Terminology

- **Stable version**: a version tag for a committed, persisted state. Every durable mutation advances the stable version.
- **Stable patch**: a batch of changes that moves the client from one stable version to another. Deterministic, replayable.
- **Streaming event**: an ephemeral real-time update (text delta, partial message). Not versioned, not persisted.
- **Committing event**: a streaming event that also advances the stable version. For example, when a message chunk finishes streaming, the server re-sends the full message with a version tag — this commits the previously-streamed deltas.

### Subscribe flow

1. Client calls `subscribe(since: lastKnownVersion?)` (nil means from scratch — equivalent to starting from the empty state at version 0).
2. Server computes and sends a **stable patch** bringing the client to the current stable version.
3. Server begins streaming events.
4. If there is a message being streamed mid-flight when the subscription starts, the server emits `message.start`, then a first `text.delta` containing all accumulated text so far, then subsequent `text.delta` events as upstream inference produces them. Mid-flight content is never part of the stable patch.
5. When a streamed message finishes, the server emits a committing event (e.g., `message.end`) carrying the **full message content** plus a new stable version. This commits all preceding deltas — the client can discard its accumulated delta state and use the full content as ground truth.
6. On disconnect, the client reconnects with its last known stable version. Already-committed content is not retransmitted.

### Composability

Think functionally. Every piece of session state starts at an initial value (empty transcript, empty queues, default settings). A subscribe call is just: compute a stable patch from the caller's version to the current version, then stream subsequent patches.

Each component independently supports subscribe:

- **Transcript**: `subscribe(since: TranscriptCursor?)` — patch is a list of appended items.
- **System lane**: `subscribe(since: QueueCursor?)` — patch is journal entries.
- **Steer lane**: `subscribe(since: QueueCursor?)` — same.
- **Follow-up lane**: `subscribe(since: QueueCursor?)` — same.
- **Settings / status**: registers — the patch is always the latest value, constant-length.

Composed together, a session subscription carries a **version vector**: `(TranscriptCursor?, QueueCursor?, QueueCursor?, QueueCursor?)`. Settings and status are registers whose patch is always the current value regardless of version, so their version can be optimized away from the vector entirely.

Within this model, queue lifecycle transitions like enqueue → materialize are just patch-level optimizations: a journal entry that has been fully materialized within the stable patch window can be coalesced away, since transmitting already-processed work as "pending" is not useful.

Each component's subscription logic can be built and tested independently, then composed into the session-level subscription.

See: ``SessionSubscribing``, ``SessionSubscription``, ``SessionSubscriptionRequest``

## Compaction

Compaction manages LLM context size by summarizing a **portion** of the LLM context.

### How it works

1. **Find a cut point**: walk backwards from the newest entry in the LLM context, accumulating tokens until the keep-recent budget is reached. The cut point must land on a valid boundary (user message, assistant message) — never on a tool result, which must stay with its tool call.
2. **Summarize the segment**: entries from the previous compaction (or the start) up to the cut point are summarized by the LLM.
3. **Append a compaction entry** to the transcript. The entry carries:
   - The summary text.
   - A `firstKeptEntryID` — the earliest entry that remains in the LLM context after compaction.
4. **The LLM context projection changes**: previous summaries are preserved, the new summary is appended after them, followed by entries from `firstKeptEntryID` onwards.

Summaries **stack** — each compaction only summarizes the segment between the previous cut point and the new one. After multiple compactions, the LLM sees: system prompt, sum₁, sum₂, ..., sumₙ, then the kept entries.

![Compaction: summaries stack across multiple compactions](compaction)

The original entries remain in the transcript — compaction only changes how the LLM context projection is computed. The transcript itself is never modified.

### Trigger

After each LLM response, check token usage:

    if (cached_input + input + output) + compaction_buffer > context_limit:
        trigger compaction

The compaction buffer should be generous — most LLMs degrade well before 100% context utilization. Use sensible defaults for now; tuning comes later.

### Fallback

In rare cases, compaction is not triggered after an LLM response, but the next input causes a context overflow error. In this case:

1. Trigger compaction after receiving the error.
2. Retry the inference with the compacted context plus the previously-materialized inputs.

### Non-goal: staged draining

Drain lanes eagerly. If accumulated input from all lanes cannot fit even after compaction, that is a hard error — the session's workflow is fundamentally broken. The system surfaces this to the user rather than attempting multi-step drain-compact cycles that produce garbage output.

## Identity

The system lane and user lanes use different author representations:

- **System lane**: items carry a source tag (e.g., `.asyncBashCallback`, `.asyncTaskNotification`), not an `Author`.
- **User lanes** (steer, follow-up): items carry an `Author`, which is `.participant(id, kind: .human | .bot)` or `.unknown`. The `.system` case of `Author` does not appear on user queue items.

Transcript entries carry a full `Author` since they can originate from any source.

See: ``Author``, ``SystemUrgentSource``
