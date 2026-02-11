# AGENTS.md

## What is Wuhu

Wuhu is a data layer + API for understanding coding agents. Not a task runner -
a session log collector and query system.

Core value: collect logs from Claude Code, Codex, OpenCode, etc. Provide APIs so
agents can query them. Git blame a line → find the session → understand the why.

Quick primer: `docs/what-is-a-coding-agent.md`.

## Status

This repo is the Swift pivot of Wuhu. It’s currently a Swift Package with:

- `PiAI`: a unified LLM client library (ported from `pi-mono`’s `pi-ai`)
- `wuhu`: a small CLI that demonstrates `PiAI` providers

## Project Structure

```
.
├── Package.swift
├── Sources/
│   ├── PiAI/                # Unified LLM API (OpenAI, OpenAI Codex, Anthropic)
│   └── wuhu/                # CLI binary demonstrating PiAI usage
├── Tests/
│   └── PiAITests/           # Provider + SSE parsing tests (swift-testing)
├── docs/
│   └── what-is-a-coding-agent.md
└── .github/workflows/
    └── ci.yml               # SwiftFormat + build + tests
```

## Local Dev

Prereqs:

- Swift 6.2 toolchain

Common commands (repo root):

```bash
swift test
swift run wuhu --help
swift run wuhu openai "Say hello"
swift run wuhu anthropic "Say hello"
```

Formatting:

```bash
swift package --allow-writing-to-package-directory swiftformat
swift package --allow-writing-to-package-directory swiftformat --lint .
```

Environment variables:

- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`

For local manual testing, `wuhu` loads API keys from its server config. Check whether `~/.wuhu` exists; if it does, assume it has the keys and use that (don’t rely on a local `.env`).

## GitHub Issue Workflow

When you are assigned to work on a GitHub issue, you must create a new branch:

1. If you are already on a new branch that has no changes and has no new commits ahead of `main`, assume that branch is for you.
2. If you are in a dirty place (uncommitted changes), stop and ask for human intervention.
3. If the current branch (either you created or already present) is behind `origin/main`, bring it up to the latest `main` before you start your work.
4. After you finish your work and perform validations, create a PR and make sure all checks pass before you finish your work.

## Notes

General documentation lives in `docs/`.
