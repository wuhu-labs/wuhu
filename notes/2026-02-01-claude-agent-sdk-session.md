# 2026-02-01 Claude Agent SDK session notes

## What I did

- Installed `@anthropic-ai/claude-agent-sdk@0.2.29` with Bun in
  `_scratch/claude-agent-sdk-smoke/`.
- Ran a minimal script using `query()` with tools disabled (`tools: []`) and the
  Bun runtime (`executable: "bun"`).

## What happened (auth + runtime)

- The run failed with: `Invalid API key · Please run /login`.
- The Claude Code subprocess exited non-zero after the SDK run.
- This strongly suggests this environment did **not** inject usable Claude
  credentials for the SDK/CLI to pick up automatically.

## What got written under `~/.claude`

Running the SDK created `~/.claude/` and wrote session artifacts:

- `~/.claude/projects/-root-repo--scratch-claude-agent-sdk-smoke/6355578a-862d-4d67-b9d7-a81fe1db6034.jsonl`
- `~/.claude/debug/6355578a-862d-4d67-b9d7-a81fe1db6034.txt`
- `~/.claude/todos/6355578a-862d-4d67-b9d7-a81fe1db6034-agent-6355578a-862d-4d67-b9d7-a81fe1db6034.json`

It also created/updated `~/.claude.json` (separate from the `~/.claude/`
directory).

## Terragon’s “Claude Pro/Max subscription” injection path (from `/root/wuhu-terragon`)

Terragon does **not** inject Pro/Max subscription auth via env vars; it injects
a Claude Code credentials file:

- It generates `~/.claude/.credentials.json` in the sandbox with a
  `claudeAiOauth` object containing:
  - `accessToken`
  - `expiresAt`
  - `scopes`
  - `subscriptionType` (mapped from `organization_type`, e.g. `claude_pro` →
    `pro`, `claude_max` → `max`)
- This comes from an OAuth flow that uses the `claude.ai` authorize endpoint
  when the auth type is `"subscription"`.
- At runtime, the daemon avoids setting `ANTHROPIC_API_KEY` when that file
  exists (so Claude Code uses the oauth creds file instead of an API key).

Implication for a “background Claude Code” web integration: if you want “shared
auth”, the simplest compatible artifact to inject is a valid
`~/.claude/.credentials.json` (Claude subscription OAuth) rather than trying to
thread API keys through the Agent SDK process environment.
