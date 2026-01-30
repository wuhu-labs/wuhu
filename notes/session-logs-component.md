# Session Logs Component

First component to build. The foundation of Wuhu.

## What it is

A place to store and query coding agent session logs from any source (Claude Code, Codex, OpenCode, etc).

## Storage

- Raw logs go to object storage (R2), treated as append-only tree (Claude Code's model - new entries are leaves pointing to parent)
- "Projections" derived from raw logs, stored in Postgres for querying
- Projections are always recomputable from raw

## MVP Projections

- Distilled turns: user input + final AI reply for each agentic loop turn
- Basic FTS on distilled content

## Metadata

- Comes through dedicated channels (not derived for MVP)
- Repo, author, topic, parent session (for subagents)
- Later: derived metadata like keyword summaries

## API Shape

- Upload new session
- Update existing session (new version must be superset of old)
- Query projections (FTS)
- Fetch raw session

## Worker

- Redis stream trigger on upload/update
- Extracts distilled turns, writes to Postgres

## Philosophy

- No smart features - just storage and primitives
- Agents compose these primitives themselves
- Easy to mock, easy to test
