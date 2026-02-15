# Interactive cleanup notes

This file is a scratchpad for refactors/architecture changes noted during interactive review.

## WuhuService prompt lifecycle

- `promptDetached` currently acts as an execution constructor (builds `Agent`, decides request options, triggers compaction) rather than enqueuing a unit of work to a long-lived session actor.
- Desired mental model: “insert into a queue, nudge if needed” managed by a *living* per-session actor/object (not just Swift actor serialization), which owns:
  - request option defaults / selection
  - compaction policy and when it runs
  - the long-lived `Agent` (or execution loop) and transcript synchronization

### Refactor in-progress

- Introduced `WuhuSessionAgentActor` (per session) that owns a persistent `PiAgent.Agent` instance.
- For now it still refreshes agent context via `setSystemPrompt/setModel/setTools/replaceMessages` per prompt (safer, keeps semantics), but the end goal is to stop rebuilding context from transcript and instead make the session actor the source of truth (and write transcript entries as a projection).

## RequestOptions in promptDetached

- `promptDetached` builds `RequestOptions` inline (policy mixed into orchestration).
- Bug: `let sessionEffort = settingsOverride != nil ? settingsOverride?.reasoningEffort : Self.extractReasoningEffort(from: header)` fails to fall back to header when override exists but effort is nil; should be `settingsOverride?.reasoningEffort ?? Self.extractReasoningEffort(from: header)`.
- Heuristic defaulting based on `model.id.contains("gpt-5") || model.id.contains("codex")` is brittle; prefer capability/config-driven defaults.

## Compaction in promptDetached

- Compaction is decided/executed inside `promptDetached` via `maybeAutoCompact(...)` (policy + side-effects inside the prompt entrypoint).
- Desired: compaction policy belongs to the session actor/loop so it can run at consistent boundaries (e.g., before processing a queued input, between turns, or when context threshold exceeded), rather than being tightly coupled to the request API call.

## Naming / queue primitives

- `sessionLoopContinuations` is technically accurate but hard to read (Continuation ≠ “continuation-passing style” in most readers’ heads).
- Consider renaming to `sessionCommandSenders` / `sessionCommandChannels`, or wrapping `AsyncStream.Continuation` in a small local `Channel` type (`send`, `finish`, `stream`) for readability and future policy changes (buffering/backpressure).
