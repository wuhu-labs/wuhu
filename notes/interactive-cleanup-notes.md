# Interactive cleanup notes

This file is a scratchpad for refactors/architecture changes noted during interactive review.

## WuhuService prompt lifecycle

- `promptDetached` originally acted as an execution constructor (builds `Agent`, decides request options, triggers compaction) rather than enqueuing a unit of work to a long-lived session actor.
- Desired mental model: “insert into a queue, nudge if needed” managed by a *living* per-session actor/object (not just Swift actor serialization), which owns:
  - request option defaults / selection
  - compaction policy and when it runs
  - the long-lived `Agent` (or execution loop) and transcript synchronization

### Refactor in-progress

- Introduced `WuhuSessionAgentActor` (per session) that owns a persistent `PiAgent.Agent` instance.
- Moved the bulk of `promptDetached` preparation (context injection, request options, compaction) into the session actor (so `WuhuService` becomes a thin router).
- For now it still refreshes agent context via `setSystemPrompt/setModel/setTools/replaceMessages` per prompt (safer, keeps semantics), but the end goal is to stop rebuilding context from transcript and instead make the session actor the source of truth (and write transcript entries as a projection).

## RequestOptions in promptDetached

- `promptDetached` builds `RequestOptions` inline (policy mixed into orchestration).
- Fixed: effort now properly falls back to header when override exists but effort is nil.
- Heuristic defaulting based on `model.id.contains("gpt-5") || model.id.contains("codex")` is brittle; prefer capability/config-driven defaults.

## Compaction in promptDetached

- Compaction is decided/executed inside `promptDetached` via `maybeAutoCompact(...)` (policy + side-effects inside the prompt entrypoint).
- Desired: compaction policy belongs to the session actor/loop so it can run at consistent boundaries (e.g., before processing a queued input, between turns, or when context threshold exceeded), rather than being tightly coupled to the request API call.

## Naming / queue primitives

- `sessionLoopContinuations` is technically accurate but hard to read (Continuation ≠ “continuation-passing style” in most readers’ heads).
- Consider renaming to `sessionCommandSenders` / `sessionCommandChannels`, or wrapping `AsyncStream.Continuation` in a small local `Channel` type (`send`, `finish`, `stream`) for readability and future policy changes (buffering/backpressure).

## Per-session idle/execution state

- Session-scoped state (`pendingModelSelection`, `lastAssistantMessageHadToolCalls`, idle publication) lives in `WuhuSessionAgentActor`.
- Remaining desired direction: session actor should own a real work queue (accept new prompts while busy, process sequentially) instead of throwing “already executing”.
