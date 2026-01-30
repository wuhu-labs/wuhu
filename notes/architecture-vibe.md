# Wuhu Architecture Vibe

## The Pivot

Wuhu is not Terragon. Terragon was "agents do your coding tasks". Wuhu is a data layer + API for understanding coding agents.

Core value:
- Collect session logs from all agents (Claude Code, Codex, OpenCode, etc)
- Provide APIs for querying - agents use these to understand code context
- Git blame a line → find the session that wrote it → understand the why

No fancy dashboards. Just storage, APIs, and tools that smart agents consume.

## Philosophy

- Composition over integration - expose primitives, let agents compose
- Small interfaces, easy mocks - UI dev doesn't need real sandboxes
- Stories as specs - one artifact for tests, health checks, and UI previews
- GitHub-optional - mock locally, polling for no-domain setups
- Infrastructure-agnostic contracts - "I need a cache" not "I need Redis"

## Components

### Session Logs (see session-logs-component.md)
First component. Foundation of Wuhu.

### Controller
Service that sits between main app and sandboxes:
- Provides credentials to sandboxes (LLM tokens, GitHub PAT)
- Proxies LLM calls (sandbox never sees real tokens)
- Could proxy preview URLs
- Adapts to deployment mode (self-hosted runner vs hosted sandbox)

### Sandbox + Daemon
- Sandbox: ephemeral container/VM
- Daemon: agent runtime inside, configured with endpoints from Controller
- Daemon doesn't know or care about deployment mode

### GitHub Abstraction
Split into verbs and observations:

Verbs (mutations):
- clone, checkout, commit, push
- create PR, update PR, merge PR

Observations (queries):
- branch status, diff, log
- PR state, checks status
- webhook events / poll for changes

Both Daemon and main app use this. Daemon needs verbs (including create PR). Main app needs both.

Mockable for local dev. Polling vs webhooks are two implementations of observation side.

## Main App Architecture

Event-driven + periodic catchup pattern:
- Triggers: events (webhook, user action) OR cron (catch missed events)
- Actions: stateless functions that evaluate state and act
- Idempotent - same logic runs regardless of trigger source

No long-running worker processes managing state. Just functions triggered by events or time.

## Merge Queue Feature (Example)

MVP: squash-only, linear history. One strategy, no rebases.

Implementation:
- One action: "evaluate if we can move forward on merge queue"
- Triggered by: PR event OR periodic cron (every 10 min)
- Actions it can take:
  - Update branch to include new commits from main
  - Call merge into main
  - If conflict: abort queue, spawn agent to fix, ask user for review

The action is idempotent. Cron catches missed events. No complex state machine.

## Infrastructure Assumptions

- Data broker: Redis (or Redis-over-HTTP for serverless)
- RDBMS: Postgres (handles FTS, vectors, everything)
- Object storage: R2/S3-compatible
- Components never expose infra directly - contracts are abstract
