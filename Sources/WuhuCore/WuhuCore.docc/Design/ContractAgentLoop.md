# Agent Loop

The agent loop drives LLM inference, tool execution, and checkpoint materialization.

> **Change policy.** The ``AgentLoop`` actor and its concurrency model require human review. Do not auto-generate changes without approval.

## Architecture

Two types, two concerns:

| Type | Concern | Who writes it |
|------|---------|---------------|
| ``AgentLoop`` | Orchestration, serialization, lifecycle, observation | Human-reviewed |
| ``AgentBehavior`` | Persistence, inference, tools, drain, compaction, domain logic | LLM-implemented |

The loop delegates all domain decisions to the behavior. It handles only **when** and **safely**.

## Action / Reducer Pattern

All IO methods on ``AgentBehavior`` persist to the database and return **actions** — value types that describe what changed. The loop applies actions to in-memory state via ``AgentBehavior/apply(_:to:)`` (a pure, synchronous reducer), then emits them as observation events.

This design yields a free invariant: for every IO operation, `apply(actions, state) == loadState(db)`. If the in-memory state after applying actions doesn't match a fresh load from the database, either the persistence, the action, or the reducer is wrong.

## Single Writer

Each loop has exactly one ``AgentLoop`` actor. It loads state from the database once, then serves all reads from memory. Every mutation routes through ``serialized(_:)``.

## Persist First

One rule: **persist to the database, then return actions, then apply to memory.** If the process crashes between the persist and the apply, the database is consistent and the state is rebuilt on next load via ``AgentBehavior/loadState()``.

There is no special crash recovery codepath. The loop's normal sequence — recover stale tool calls, drain, infer — handles all states identically.

## Serialization

Swift actors re-enter at every `await`. For mutations that span an `await` (persist, then apply), actor isolation alone is not sufficient.

The loop uses task-chaining: each ``serialized(_:)`` block passes the current state (by value) to a work closure. The closure does IO and returns actions. The loop applies the actions and emits them. Each block runs to completion before the next starts.

Long-running IO — inference and tool execution — runs **outside** serialization so the loop stays responsive. External commands via ``AgentLoop/send(_:)`` go through the same serialized chain.

## Lifecycle

The loop is started once via ``AgentLoop/start()``. It waits for a signal (triggered by ``send(_:)``), runs the loop inline until idle, then returns to waiting. No unstructured tasks — the loop runs within `start()`. Cancelling the start task tears down everything via structured concurrency.

There are no explicit running/idle markers. The behavior manages a `has_work` flag in the database atomically with other operations (set true on enqueue, set false when queues are empty after the last inference).

## Input Model

The loop has two abstract drain checkpoints:

- **Interrupt checkpoint**: after tool results are collected, before next inference. The behavior drains interrupt-priority items (e.g., system injections + steer messages in Wuhu).
- **Turn boundary**: the loop would otherwise go idle. The behavior drains turn-boundary items (e.g., follow-up messages in Wuhu).

The loop does not know about queue lanes, cancelability, or journal semantics. It calls ``AgentBehavior/drainInterruptItems(state:)`` and ``AgentBehavior/drainTurnItems(state:)`` and receives actions.

## Observation

``AgentLoop/observe()`` returns a gap-free `(state, inflight, stream)` tuple. The snapshot and stream registration are atomic — no events are missed.

Two kinds of events:

| Kind | Persisted | Advances state |
|------|-----------|----------------|
| ``AgentLoopEvent/committed(_:)`` | Yes | Yes |
| ``AgentLoopEvent/streamDelta(_:)`` | No | No |

Stream lifecycle is explicit: ``AgentLoopEvent/streamBegan`` and ``AgentLoopEvent/streamEnded`` bracket the streaming phase. The `inflight` field in the observation carries accumulated deltas if inference is mid-flight at observation time.

## Streaming

During inference, the behavior yields ``AgentBehavior/StreamAction`` deltas via an ``AgentStreamSink``. The loop accumulates deltas in an `inflight` buffer and emits ``AgentLoopEvent/streamDelta(_:)`` events. When inference completes, the assistant entry is persisted (committed action) and the inflight buffer is cleared.

Streaming state is **separate** from committed state. This preserves the free test invariant — `apply(actions) == loadState()` holds for committed actions without needing to account for ephemeral streaming state.

## Layering

The loop is general-purpose. Domain-specific concerns (Wuhu's three-lane queues, session identity, subscription versioning) live in a wrapper layer:

- **Loop → Session**: full state + unversioned event stream (via `observe()`)
- **Session → Client**: versioned diff + stream (minimal payload, composable per-component subscriptions)

The session layer consumes the loop's event stream, maps committed actions to versioned patches, and forwards stream deltas as ephemeral events. Subscription backfill comes from the database, not from the loop.
