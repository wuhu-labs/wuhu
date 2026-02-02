# Codex integration options for Wuhu (SDK vs `codex exec` vs `codex app-server`)

Date: 2026-02-01

Codex upstream snapshot reviewed:

- Repo: `openai/codex`
- Commit: `3dd9a37e0bb7af065eed668c2c6a4c96cec85320` (Sat Jan 31 2026)

## Executive summary

If I were integrating Codex into Wuhu today, I would target
**`codex app-server`** as the primary integration surface, and treat
**`codex exec --experimental-json`** as a fallback for headless/one-shot use.

Reason: `app-server` is the only surface that is (a) designed as an integration
API for rich clients, (b) exposes the richest event stream (output deltas,
approvals, plan mode items, terminal interactions, etc.), and (c) has a
first-class schema/type export story. The TypeScript SDK is useful for quick
Node embedding, but it is functionally “`codex exec` with types”.

## What each option actually is (per upstream code)

### 1) TypeScript SDK (`@openai/codex-sdk`)

What it does:

- Spawns a **bundled** `codex` binary and runs `codex exec --experimental-json`.
- Writes the full prompt to stdin and closes stdin immediately.
- Reads JSONL events from stdout and yields them as parsed objects.

Evidence in upstream:

- `sdk/typescript/src/exec.ts` builds args
  `["exec", "--experimental-json", ...]` and then:
  - `child.stdin.write(args.input); child.stdin.end();`

Implications:

- It is **not** an “SDK for Codex’s internal APIs”; it’s an SDK for _one
  specific CLI mode_ (`exec`).
- It can stream **output** events (`runStreamed()`), but it can’t provide
  interactive behaviors that require a long-lived bidirectional session
  (approvals prompts, terminal stdin streaming, etc.) unless `exec` itself
  supports it.

### 2) `codex exec` (CLI subcommand)

What it does:

- One-shot “run the agent and exit” mode with optional session resume.
- `--json` / `--experimental-json` emits JSONL events to stdout.

Important limitations (today):

- The prompt is read to EOF before work begins when reading from stdin.
  - In `codex-rs/exec/src/lib.rs`, `resolve_prompt()` uses
    `std::io::stdin().read_to_end(&mut bytes)`.
- The JSONL stream is intentionally **incomplete** vs what the core emits:
  - Output streaming and terminal interaction are TODOs:
    - `codex-rs/exec/src/event_processor_with_jsonl_output.rs` has
      `handle_output_chunk()` and `handle_terminal_interaction()` returning
      `vec![]`.
  - Plan-mode plan items are not surfaced as an item at all:
    - It watches for `TurnItem::Plan` and stores `last_proposed_plan`, but emits
      no event for it.

Implications:

- You can build a simple “agent runner” around it, but it’s not a great “rich
  telemetry surface”.
- “Streaming input” in the Claude Code sense (steer/queue while the agent is
  running) is structurally awkward: `exec` is process-per-turn, and stdin is
  treated as a one-shot prompt channel.

### 3) `codex app-server` (the API used by VS Code extension and other rich clients)

What it is:

- A **bidirectional JSON-RPC 2.0** protocol over stdio (JSONL framing).
- Explicit primitives: **Thread / Turn / Item**, with streaming notifications
  for item start/delta/complete.
- It explicitly supports schema generation:
  - `codex app-server generate-ts --out DIR`
  - `codex app-server generate-json-schema --out DIR`

Evidence in upstream:

- `codex-rs/app-server/README.md` is a real protocol spec.
- Protocol is versioned in code
  (`codex-rs/app-server-protocol/src/protocol/v2.rs`) with TS exports.

Implications:

- This is the cleanest “product-grade” integration boundary: you can treat
  `codex` as a daemon process and drive it from your own UI/service.
- You get a richer, more structured event model than `exec` JSONL today (deltas,
  approvals, terminal interactions, better item types).
- Operationally, `codex app-server` is not a separate “server binary”; it runs
  inside the same `codex` executable (the CLI dispatches into
  `codex_app_server::run_main(...)`).

#### How “well typed” is app-server?

Very well typed (by the standards of a local-process JSON protocol):

- The protocol is defined as Rust enums/structs (not “stringly typed” JSON
  blobs) and is organized around discriminated unions:
  - `codex-rs/app-server-protocol/src/protocol/common.rs` generates a tagged
    `ClientRequest` enum (tagged by `method`) with concrete `params` +
    `response` types per method, and also defines typed `ServerRequest` /
    `ServerNotification` enums.
  - `codex-rs/app-server-protocol/src/protocol/v2.rs` defines the v2 “domain
    model” for Thread/Turn/Item plus all the delta notifications and approval
    request/response shapes.
- There is a first-class type export path:
  - Many protocol types derive `ts_rs::TS` and `schemars::JsonSchema`.
  - The `codex app-server generate-ts` / `generate-json-schema` commands
    generate artifacts that match the specific Codex binary version you run.

“Untyped islands” still exist where they have to:

- Tool arguments/results and schema-driven outputs are represented as
  `serde_json::Value` / `JsonValue` in various places, because they’re
  inherently dynamic (user-defined tool schemas, model tool calls, JSON-schema
  constrained outputs).

#### Is the VS Code extension source in this repo?

No. This repo contains the `codex app-server` protocol + implementation that
powers the VS Code extension, but not the extension’s source itself.

## Your specific concerns

### Streaming input (the “Claude Code style” feature)

What Codex has today:

- There is an experimental “steer” UX feature in Codex CLI:
  - `codex-rs/core/src/features.rs` defines `Feature::Steer` (“Enter submits
    immediately; Tab queues messages when a task is running.”).
  - In the TUI this is implemented as a keybinding behavior (Enter vs Tab), not
    as a new model/provider capability.
  - Under the hood, Codex core already supports “pending input” injection into
    an in-flight turn (`inject_input()`), and consumes that pending input to
    trigger a follow-up sampling cycle within the same turn loop.

What that means for integration:

- This is fundamentally a **client UX behavior**, but it depends on a core
  capability (pending-input injection) that is not exposed in all integration
  surfaces.
- `codex exec` + TS SDK:
  - Not a good fit for steer-style interaction because the process is “one run
    then exit”, and stdin is treated as “give me the prompt (read-to-EOF), then
    I’m done”.
  - It does support a graceful interrupt via Ctrl+C / SIGINT (submits
    `Op::Interrupt`), but it cannot accept additional user input mid-run; steer
    requires interrupt + restart of `codex exec`.
- `codex app-server`:
  - The public v2 protocol does not currently expose “append more user input to
    the same in-flight turn” (it exposes `turn/start` and `turn/interrupt`).
  - However, because core already supports pending-input injection, `app-server`
    is the right place to expose a first-class “steer” API (e.g. a custom
    `turn/inject` RPC that targets an existing `turnId` and injects new
    `UserInput` into the active turn).
  - Without modification, you can still implement steer UX via interruption +
    new turn:
    - “Enter” => `turn/interrupt` then `turn/start` with the new message.
    - “Tab” => queue locally; send after `turn/completed`.

Bottom line: if “streaming input into an in-flight turn” is a hard requirement,
**you’ll need app-server + a small protocol extension**, because neither `exec`
nor app-server expose injection today even though core supports it.

### Plan mode / collaboration modes

There are two related but distinct concepts in upstream:

1. **Collaboration modes** (plan/code/pair_programming/execute presets)

- These are core “modes” with their own instruction templates under
  `codex-rs/core/templates/collaboration_mode/`.
- `app-server` supports setting `collaboration_mode` per turn (`TurnStartParams`
  in protocol v2) and listing presets (`CollaborationModeList*` types).
- In `exec` mode, you can likely only reach these indirectly via config
  overrides; there is no first-class request field, and the JSONL projection is
  thinner.

2. **Collab tools** (multi-agent: `spawn_agent`, `send_input`, `wait`,
   `close_agent`)

- Implemented as tools in core (`codex-rs/core/src/tools/handlers/collab.rs`)
  and surfaced as `collabToolCall` items in `app-server` and as
  `collab_tool_call` items in `exec` JSONL.

Bottom line: if Wuhu wants to understand or replay rich “plan mode” semantics
(plan items + deltas), the `exec` JSONL path is currently not great;
`app-server` has explicit plan items and plan deltas.

### Background shells / background terminals / shell snapshots

Upstream has a feature registry with relevant toggles:

- `Feature::UnifiedExec` (“Background terminal”) and `Feature::ShellSnapshot`
  are defined in `codex-rs/core/src/features.rs`.

Observations:

- `app-server`’s item model includes command output deltas and terminal input
  notifications (see `TerminalInteractionNotification` and
  `CommandExecutionOutputDeltaNotification` in protocol v2).
- `exec --experimental-json` currently does **not** forward output deltas or
  terminal interactions (TODOs), so it can’t faithfully represent “background
  terminal” behavior even if enabled.

Bottom line: if you care about these newer runtime features at all, treat them
as effectively **`app-server`-only** for integration purposes.

## Software engineering trade-offs (cleanliness vs unstable API)

### Why `app-server` is cleaner than “CLI exec scraping”

- **Intentional integration boundary**: it exists specifically to power IDE
  integrations (not an afterthought).
- **Typed, versioned protocol**: upstream maintains a protocol crate with TS
  exports and a README spec.
- **Better mapping to Wuhu’s worldview**: Thread/Turn/Item is very close to what
  Wuhu likely wants to store/query anyway.
- **Bidirectional**: approvals and other “server asks client” flows exist, which
  is important if Wuhu ever needs to run Codex, not just observe it.

### The real risk with `app-server`

- You are coupling to a _fast-moving product surface_ (IDE features,
  experimental endpoints).
- There’s no strong “semver’d HTTP API” promise; it’s still a local-process
  protocol.

Mitigations that make it reasonable anyway:

- **Pin the Codex version** you run inside any Wuhu-managed sandbox/daemon
  environment.
- **Store raw protocol messages** (notifications + requests/responses) in Wuhu
  as the source of truth, and normalize into Wuhu’s schema as a derived view.
- Treat “experimental” parts of the protocol as optional: build feature
  detection and ignore unknown item types/fields.
- Consider generating protocol types at build time using
  `codex app-server generate-ts` for the pinned version.

### Where the TS SDK fits

Use it when:

- You only need **non-interactive, one-shot runs** from Node, and “missing”
  event detail is acceptable.

Avoid it when:

- You need newer “rich client” behaviors or want to avoid being bottlenecked by
  what `exec` chooses to project.
- You need a stable, growing contract for a long-lived integration.

## Recommendation for Wuhu

If Wuhu intends to _run Codex_ (or simulate Codex UI surfaces) in any meaningful
way:

1. Implement a Wuhu “Codex adapter” against **`codex app-server` protocol v2**.
2. Treat `codex exec --experimental-json` as a fallback mode for
   “fire-and-forget runs” (or environments where you cannot keep a daemon
   process).
3. Only use the TypeScript SDK if you want a convenience wrapper in Node;
   conceptually it should be replaceable by a tiny in-house wrapper around
   `codex exec`.

If Wuhu intends to _primarily ingest/understand sessions created by developers
running Codex themselves_:

- Still prefer `app-server` for ingestion: it can `thread/list` and
  `thread/resume` and stream canonical `item/*` events in a stable shape,
  instead of reverse-engineering Codex’s local storage format.
