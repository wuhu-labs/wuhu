# AGENTS.md

## What is Wuhu

Wuhu is a data layer + API for understanding coding agents. Not a task runner - a session log collector and query system.

Core value: collect logs from Claude Code, Codex, OpenCode, etc. Provide APIs so agents can query them. Git blame a line → find the session → understand the why.

See `notes/architecture-vibe.md` for full architecture discussion.

## Development Environment

You're running in a self-hosted Terragon instance. The original Terragon product is dead - no commercial future, no data retrieval from the old hosted version.

**Important paths:**
- `.` - Wuhu repo (this repo)
- `../wuhu-terragon` - Terragon source code, always available

The `terragon-setup.sh` script clones Terragon and runs `pnpm install`. This runs before your environment starts.

## Using Terragon Code

Terragon has working implementations of:
- Sandbox providers (E2B, Docker, Daytona)
- Daemon (agent runtime)
- GitHub integration (PRs, checkpoints, webhooks)
- Real-time updates (PartyKit)
- Web UI patterns

Reference it freely. Copy and adapt what makes sense. But Wuhu has different goals - don't inherit Terragon's tight coupling.

## Key Differences from Terragon

Terragon: "agents do your coding tasks" - full product, tightly integrated
Wuhu: "understand your coding agents" - data layer, composition-first, modular

Wuhu principles:
- Expose primitives via API/MCP, let agents compose
- Small interfaces, easy mocks
- GitHub-optional (mock locally, polling for no-domain setups)
- Infrastructure-agnostic contracts

## Notes

Architecture discussions live in `notes/`:
- `architecture-vibe.md` - overall system design
- `session-logs-component.md` - first component spec
