# Agent Loop

The agent loop drives LLM inference, tool execution, and checkpoint materialization for a Wuhu session.

> **Change policy.** The ``SessionAgent`` and its concurrency model require human review. Do not auto-generate changes without approval.

## Single Writer

Each session has exactly one owner — the ``SessionAgent`` actor. It loads state from SQLite once, then serves all reads from memory. Every mutation routes through the agent. There are no concurrent writers, no cache invalidation, no read-your-writes concerns. This is the same pattern as `UIDocument`: load, serve from memory, persist selectively.

The ``SessionAgent`` is the only code that needs to be correct for session state to be consistent. Everything else — persistence implementations, tools, inference providers — can be developed and tested against its interface without understanding the concurrency model.

## Persist First

The agent follows one rule: **persist to SQLite, then update in-memory state**. If the process crashes between the two, the database is consistent and the in-memory state is simply rebuilt on next load.

This rule is enforced by human-approved code in the ``SessionAgent``. Implementors of ``SessionPersistence`` do not need to reason about the in-memory cache — they only need to ensure each method is **atomic and crash-safe** (see the protocol's documentation for transaction requirements).

There is no special crash recovery codepath. The loop's normal sequence — resume pending tool calls, materialize checkpoint, infer if needed — handles all recovery states identically.

## Serialization

Swift actors re-enter at every suspension point. For mutations that span an `await` (persist, then update memory), actor isolation alone is not sufficient. The agent serializes all mutating operations so each runs to completion before the next starts, eliminating interleaving between enqueue and the loop's state transitions.

Long-running IO — LLM inference and tool execution — runs outside this serialization, so the agent remains responsive to enqueue and cancel during inference.

## Lifecycle

The agent is started once. It waits for a signal (triggered by enqueue), runs the loop inline until idle, then returns to waiting. No unstructured tasks — the loop runs within the `start()` call. Cancelling the start task tears down everything via structured concurrency.
