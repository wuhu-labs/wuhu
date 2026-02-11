# Context Files (AGENTS.md)

Wuhu supports injecting project context files into the **LLM system prompt** at runtime.

## Files

For each session, Wuhu looks in the session’s working directory (`WuhuSession.cwd`) for:

- `AGENTS.md`
- `AGENTS.local.md`

Either file may be missing; if both are missing, nothing is injected.

## Injection Format

When present, files are appended to the effective system prompt as a single section:

- `# Project Context`
- one `## <absolute filepath>` heading per file, followed by the file’s raw contents

This ensures the model can attribute each instruction to a specific file path.

## Persistence (Non-Goal)

Context file contents are **not** persisted into the session transcript in SQLite.

Instead, they are loaded and concatenated dynamically right before calling LLM providers. This keeps the persisted chain (header + messages + tool executions + compactions) free of filesystem-dependent prompt material.

Because the injection is dynamic:

- If the server restarts, the loaded context may differ (e.g., files changed on disk).
- If a session’s in-memory actor is evicted, it will reload context on next use.

Preserving an identical injected context across restarts/evictions is intentionally a non-goal for v1.

## Caching

Context files are cached **in memory** per session via a per-session context actor managed by `WuhuService`.

- Cache key: session id (actor lifetime)
- Reload trigger: file set or `(mtime, size)` snapshot changes
- Eviction: least-recently-used when the server exceeds a small fixed number of cached session actors

