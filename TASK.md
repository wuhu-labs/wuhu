# Align WuhuCore to the Contracts

## Context

The `Sources/WuhuCore/Contracts/` directory and the two DocC design docs
(`ContractAgentLoop.md`, `ContractSession.md`) are the result of careful human
iteration. They define how Wuhu sessions should work — the agent loop, session
layer, queues, subscriptions, transcript, identity, settings.

The rest of the codebase was vibe-coded by earlier AI passes and doesn't follow
these contracts. The main problem: `WuhuSessionAgentActor` wraps `PiAgent.Agent`
and starts a new agent execution each time a prompt arrives, rather than being a
long-running actor with a message channel. It crashes after a few turns for
reasons nobody has debugged. The persistence and service layers were built to
serve that broken model.

`../wuhu-workspace/issues/` has the full issue history (WUHU-0001 through
WUHU-0010, all closed). These show what the system is supposed to do and include
manual testing examples you should use for validation.

## Intent

Complete refactor of WuhuCore grounded in the contracts. Read every file in
`Contracts/` and both design docs before writing code — they are the source of
truth and should not be modified.

All existing implementation code is disposable. No data migration, no old format
detection, no backwards compatibility shims. Nuke the SQLite schema and start
fresh. The only thing to preserve is the server/runner/client transport layer
(`WuhuServer`, `WuhuRunner`, `WuhuClient` targets) — endpoints may need
rewiring internally but the HTTP + WebSocket surface stays.

## Tests

The action/reducer design gives us a free test invariant: for every IO method on
the behavior, `apply(actions, state) == loadState(db)`. Write unit tests that
exercise this for every IO method. Also test the reducer in isolation, crash
recovery, drain logic, and compaction.

Once wired end-to-end, do manual testing with real LLM calls via the CLI. The
closed issues in `../wuhu-workspace/issues/` have concrete scenarios — model
switching, async bash completion injection, stop mid-execution, tool call
lifecycles.

## Success Criteria

- `swift build` and `swift test` pass clean
- CLI works end-to-end: create session, prompt, stream response, tool calls
- Unit tests exercise the free test invariant across behavior methods
- No `WuhuSessionAgentActor` code remains
- No two-mode / format detection / backwards compat
