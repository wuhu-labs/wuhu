# Agentic Loop Contracts

The agentic loop is the state machine that drives LLM inference, tool execution, and checkpoint materialization for a Wuhu session.

## Why Replace PiAgent

PiAgent holds input queues and message history as in-memory arrays inside a Swift actor. This makes crash resilience impractical: on restart, the in-memory state is gone, and syncing database state back into the actor fights the abstraction at every step.

The agentic loop is simple control flow. Its value is not in algorithmic complexity but in providing **well-defined hook points** at each state transition, so that:

- Production code implements hooks with SQLite persistence for crash resilience.
- Tests implement hooks with in-memory state for speed and determinism.
- Benchmarks implement hooks with recording and playback.

Additionally, PiAgent works with raw `Message` values that have no identity. Wuhu needs every item to carry a `TranscriptEntryID` — the loop and all its hooks operate on identified entries.

## Session Owner

Each session has a single **owner** — a long-lived object that:

- Loads session state from SQLite on demand.
- Serves reads from memory after the initial load.
- Persists all durable mutations to SQLite (only streaming ephemera — partial LLM deltas — are skipped).
- Provides the hook implementations that the agentic loop calls.

Because there is exactly one owner per session, there are no concurrent writers. The in-memory state and SQLite are a single logical source of truth — every read routes through the owner.

This is the same pattern as `UIDocument` or `NSManagedObjectContext`: load, serve from memory, persist selectively.

## State Machine

```
idle
  │
  ▼  (follow-up arrives, or restart after crash)
preparing
  │
  ▼  (drain lanes, build context)
inferring
  │
  ├──▶ executingTools  (response has tool calls)
  │       │
  │       └──▶ preparing  (tools done, steer checkpoint)
  │
  ├──▶ preparing  (no tool calls, steer/follow-up available)
  │
  └──▶ idle  (no tool calls, nothing queued)

At any point after inference:
  └──▶ compacting  (usage exceeds threshold)
         │
         └──▶ preparing  (compaction done, resume)
```

## Hook Protocol

The agentic loop calls into an `AgenticLoopStore` protocol at each state transition. The protocol is defined in `Contracts/AgenticLoopContracts.swift`.

### Lifecycle

- `markRunning()` — called when the loop starts or resumes. The store records the session as running (persisted, so crash recovery can find it).
- `markIdle()` — called when the loop has no more work.

### Context

- `buildContext()` — project the current transcript into LLM input: apply compaction boundaries, filter to message entries, assemble the context window.

### Checkpoint Materialization

- `drainSteer()` — drain the system and steer lanes. Move queued items into the transcript in a single transaction. Return the materialized items (with entry IDs). Called at steer checkpoints.
- `drainFollowUp()` — drain the follow-up lane. Same transactional guarantee. Called at follow-up checkpoints.

### Persistence

All persistence hooks return a `TranscriptEntryID` — the loop operates exclusively on identified entries.

- `appendAssistantEntry(_:)` — persist the assistant response immediately after inference completes.
- `toolWillExecute(toolCallID:idempotent:)` — record that tool execution has started. On crash recovery, non-idempotent tools that were started but not completed receive an error result instead of being retried.
- `toolDidExecute(toolCallID:output:)` — persist the tool result.

### Compaction

- `shouldCompact(usage:)` — evaluate whether compaction is needed given token usage from the latest inference.
- `performCompaction()` — select a prefix, generate a summary, append the compaction entry.

### Events

- `emit(_:)` — forward an `AgenticLoopEvent` to subscribers. Streaming events (inference deltas) are ephemeral and not persisted.

## Loop Control Flow

The loop is a function, generic over the store:

```swift
func runAgenticLoop(
    store: some AgenticLoopStore,
    tools: [some AgenticTool]
) async throws
```

Pseudocode:

```
store.markRunning()

loop:
    context = store.buildContext()
    response = infer(context)
    entryID = store.appendAssistantEntry(response)

    if store.shouldCompact(response.usage):
        store.performCompaction()

    if response.hasToolCalls:
        for call in response.toolCalls:
            store.toolWillExecute(call.id, idempotent: tool.isIdempotent)
            output = tool.execute(call)
            store.toolDidExecute(call.id, output)

        // Steer checkpoint: drain system + steer eagerly
        store.drainSteer()
        continue loop

    // No tool calls — turn complete
    // Follow-up checkpoint: try steer first, then follow-up
    if store.drainSteer() is not empty:
        continue loop
    if store.drainFollowUp() is not empty:
        continue loop

    store.markIdle()
    return
```

## Crash Recovery

On process restart:

1. Query SQLite for sessions marked as `running`.
2. For each, create a session owner and load state.
3. Inspect the last persisted state:
   - **Assistant response persisted, tools not started**: begin tool execution.
   - **Some tools started, not completed**: retry idempotent tools; use error results for non-idempotent ones.
   - **All tools completed**: proceed to steer checkpoint.
   - **No pending work**: check queues for follow-up.
4. Resume the loop.

The key invariant: every durable state transition is persisted before the next step begins, so the loop can always resume from the last committed state.

## Transaction Boundaries

Each hook call represents an atomic operation. The critical transaction boundaries:

1. **Checkpoint materialization** (`drainSteer`, `drainFollowUp`): move items from queue to transcript in one transaction.
2. **Tool start** (`toolWillExecute`): flip the started flag before execution begins.
3. **Tool completion** (`toolDidExecute`): persist the result after execution.
4. **Assistant entry** (`appendAssistantEntry`): persist before any tool execution starts.

The store implementation decides the exact SQLite transaction boundaries. The protocol guarantees that each call is atomic from the loop's perspective.

## Compaction Integration

Compaction is checked after each inference call. If triggered, `performCompaction()` runs before the next loop iteration. See <doc:ContractSession> for compaction semantics.

The fallback path (context overflow on the next inference) is handled by the loop: catch the overflow error, call `performCompaction()`, and retry the inference.
