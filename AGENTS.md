# AGENTS.md

## What is Wuhu

Wuhu is a data layer + API for understanding coding agents. Not a task runner -
a session log collector and query system.

Core value: collect logs from Claude Code, Codex, OpenCode, etc. Provide APIs so
agents can query them. Git blame a line → find the session → understand the why.

See `notes/architecture-vibe.md` for full architecture discussion.

## Development Environment

You're running in a self-hosted Terragon instance. The original Terragon product
is dead - no commercial future, no data retrieval from the old hosted version.

**Important paths:**

- `.` - Wuhu repo (this repo)
- `../wuhu-terragon` - Terragon source code, always available
- `../terrragon` - Additional Terragon clone for experimentation
- `../axiia-website` - Personal project with useful code patterns (main branch,
  Bun-based)
- `../axiia-website-deno` - Deno-era snapshot of Axiia Website at commit
  `df170fe8`
- `../codex` - OpenAI Codex repo, used for deep integration experiments
- `../pi-mono` - Pi coding agent monorepo, used as a reference coding harness

The `terragon-setup.sh` script installs Deno, configures git hooks, and runs
`scripts/setup-terragon.ts` to clone Terragon, Axiia Website worktrees, Codex,
and pi-mono. This runs before your environment starts.

## Using Terragon Code

Terragon has working implementations of:

- Sandbox providers (E2B, Docker, Daytona)
- Daemon (agent runtime)
- GitHub integration (PRs, checkpoints, webhooks)
- Real-time updates (PartyKit)
- Web UI patterns

Reference it freely. Copy and adapt what makes sense. But Wuhu has different
goals - don't inherit Terragon's tight coupling.

## Key Differences from Terragon

Terragon: "agents do your coding tasks" - full product, tightly integrated Wuhu:
"understand your coding agents" - data layer, composition-first, modular

Wuhu principles:

- Expose primitives via API/MCP, let agents compose
- Small interfaces, easy mocks
- GitHub-optional (mock locally, polling for no-domain setups)
- Infrastructure-agnostic contracts

## Reference Projects

### Axiia Website (`../axiia-website`)

Personal project (paideia-ai/axiia-website). Bun monorepo with Elysia server,
React Router SSR, service registry pattern, and domain API layering. Useful
patterns for API design, DI, and config management. See `notes/axiia-website.md`
for details.

## Notes

Architecture discussions live in `notes/`:

- `architecture-vibe.md` - overall system design
- `session-logs-component.md` - first component spec
- `axiia-website.md` - reference project notes
