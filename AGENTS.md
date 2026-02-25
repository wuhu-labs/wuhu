# AGENTS.md

## What is Wuhu

Wuhu is a data layer + API for understanding coding agents. Not a task runner -
a session log collector and query system.

Core value: collect logs from Claude Code, Codex, OpenCode, etc. Provide APIs so
agents can query them. Git blame a line → find the session → understand the why.

Quick primer: `docs/what-is-a-coding-agent.md`.

## Status

This repo is the Swift pivot of Wuhu. It's currently a Swift Package with:

- `PiAI`: a unified LLM client library (ported from `pi-mono`'s `pi-ai`)
- `wuhu`: a small CLI that demonstrates `PiAI` providers

## Project Structure

Never add a "project structure diagram" (tree listing) to this file. It always drifts from reality.

If you need to understand the current layout, inspect the repo directly (or use `Package.swift` / `swift package describe` as the source of truth).

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

For local manual testing, `wuhu` loads API keys from its server config. Check whether `~/.wuhu` exists; if it does, assume it has the keys and use that (don't rely on a local `.env`).

WuhuApp (active development):

- `WuhuApp` is the primary app target (macOS + iOS). New features go here unless explicitly directed otherwise.
- `WuhuApp.xcodeproj` is generated, not source-of-truth. Source-of-truth is `WuhuApp/project.yml`.
- Before building, check whether `WuhuApp/WuhuApp.xcodeproj` exists. If not, run `cd WuhuApp && xcodegen generate` first.
- Build macOS: `xcodebuild build -project WuhuApp/WuhuApp.xcodeproj -scheme WuhuAppMac -destination 'platform=macOS' -quiet`
- Build iOS: `xcodebuild build -project WuhuApp/WuhuApp.xcodeproj -scheme WuhuApp -destination 'generic/platform=iOS' -quiet`

## Workspace + Issues

This project manages issues locally at `~/.wuhu/workspace/issues/`. Each issue is a Markdown file named by its number (e.g., `0001.md`).

## Issue Workflow

Issues use the format `WUHU-####` (four digits) and live in `~/.wuhu/workspace/issues/*.md`. If you see "Fix WUHU-0001", assume it refers to an issue at that path (not GitHub Issues).

When you are assigned to work on a `WUHU-####` issue, you must create a new branch:

1. If you are already on a new branch that has no changes and has no new commits ahead of `main`, assume that branch is for you.
2. If you are in a dirty place (uncommitted changes), stop and ask for human intervention.
3. If the current branch (either you created or already present) is behind `origin/main`, bring it up to the latest `main` before you start your work.
4. After you finish your work and perform validations, create a PR and make sure all checks pass before you finish your work.

## WuhuCore / WuhuCoreClient

Before modifying anything in `Sources/WuhuCore/`, read the DocC index (`Sources/WuhuCore/WuhuCore.docc/WuhuCore.md`) to understand the module's architecture and contract boundaries.

`WuhuCoreClient` contains the client-safe subset of WuhuCore: session contracts, queue types, identifiers, and `RemoteSessionSSETransport`. It has no GRDB or server-side dependencies and is safe to use on iOS. `WuhuCore` re-exports `WuhuCoreClient`, so server-side code can use everything from either module.

Files under `Sources/WuhuCoreClient/Contracts/` and `Sources/WuhuCore/Contracts/` are the human-authored alignment surface. **Do not add, remove, or modify contract types without explicit human approval.**

## Notes

General documentation lives in `docs/`.

## Collaboration

When the user is interactively asking questions while reviewing code:

- Treat the user's questions/concerns as likely-valid signals, not as "user error".
- Take a neutral stance: verify by inspecting the repo before concluding who's right.
- Correct the user only when there's a clear factual mismatch, and cite the exact file/symbol you're relying on.
- Assume parts of the codebase may be sloppy/LLM-generated; prioritize clarity and maintainability over defending the status quo.
