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

Never add a “project structure diagram” (tree listing) to this file. It always drifts from reality.

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

For local manual testing, `wuhu` loads API keys from its server config. Check whether `~/.wuhu` exists; if it does, assume it has the keys and use that (don’t rely on a local `.env`).

WuhuApp / XcodeGen:

- `WuhuApp.xcodeproj` is generated, not source-of-truth. Source-of-truth is `WuhuApp/project.yml`.
- Before running any Xcode/iOS command that expects the project file (`xcodebuild`, opening the project, TestFlight scripts), check whether `WuhuApp/WuhuApp.xcodeproj` exists.
- If it does not exist, run `cd WuhuApp && xcodegen generate` first.

## Workspace + Issues

This project manages issues in a dedicated workspace repo: `wuhu-labs/wuhu-workspace`.

When working in this repo, clone any related repos you need as siblings next to this repo (same parent directory). Example: clone `wuhu-workspace` to `../wuhu-workspace`.

Common sibling repos (clone on demand, next to this repo):

- `../wuhu-workspace` (issue tracker + project management; issues are `WUHU-####`)
- `../wuhu` (main Wuhu repo)
- `../wuhu-terragon` (reference implementations and patterns)
- `../pi-mono` (reference harness + model/provider lists)
- `../codex` (OpenAI Codex repo, for integration experiments)
- `../axiia-website` (reference patterns)

Starting new work:

- Clone sibling repos on demand (only what you need).
- Refresh a sibling repo with `git pull` only if you are on its default branch (usually `main`) and the working tree is clean (no local edits). If not, stop and ask for human intervention.

## Issue Workflow

Issues use the format `WUHU-####` (four digits) and live in `../wuhu-workspace/issues/*.md`. If you see “Fix WUHU-0001”, assume it refers to an issue in `wuhu-workspace` (not GitHub Issues).

When you are assigned to work on a `WUHU-####` issue, you must create a new branch:

1. If you are already on a new branch that has no changes and has no new commits ahead of `main`, assume that branch is for you.
2. If you are in a dirty place (uncommitted changes), stop and ask for human intervention.
3. If the current branch (either you created or already present) is behind `origin/main`, bring it up to the latest `main` before you start your work.
4. After you finish your work and perform validations, create a PR and make sure all checks pass before you finish your work.

## Notes

General documentation lives in `docs/`.
