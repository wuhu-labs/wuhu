# Agent Loop

The agent loop drives LLM inference, tool execution, and checkpoint materialization for a Wuhu session.

> **Change policy.** The ``SessionAgent`` and its concurrency model require human review. Do not auto-generate changes without approval.

## Architecture

Three types, three concerns:

| Type | Concern | Who writes it |
|------|---------|---------------|
| ``SessionAgent`` | Concurrency, lifecycle, persistence ordering | Human-reviewed |
| ``SessionState`` | Plain data (fields only, no logic) | Human-reviewed |
| ``SessionPolicy`` | Decisions: context, materialization, compaction, inference, tools | LLM-implemented |

The agent delegates all decisions to the policy. It handles only **when** and **safely**.

## Single Writer

Each session has exactly one ``SessionAgent`` actor. It loads state from SQLite once, then serves all reads from memory. Every mutation routes through the agent. Same pattern as `UIDocument`: load, serve from memory, persist selectively.

## Persist First

One rule: **persist to SQLite, then update in-memory state**. If the process crashes between the two, the database is consistent and the in-memory state is rebuilt on next load.

There is no special crash recovery codepath. The loop's normal sequence — recover stale tool calls, materialize checkpoint, infer if needed — handles all states identically.

## Serialization

Swift actors re-enter at every `await`. For mutations that span an `await` (persist, then update memory), actor isolation alone is not sufficient.

The agent uses an inline task-chaining mechanism (`serialized`): copy state out, pass as `inout` to the work closure, write back. Each block runs to completion before the next starts. Long-running IO — inference and tool execution — runs outside serialization so the agent stays responsive.

## Lifecycle

The agent is started once. It waits for a signal (triggered by enqueue), runs the loop inline until idle, then returns to waiting. No unstructured tasks — the loop runs within `start()`. Cancelling the start task tears down everything via structured concurrency.
