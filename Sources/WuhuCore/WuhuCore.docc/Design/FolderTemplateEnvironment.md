# Folder Template Environments

Wuhu supports an environment type named `folder-template` intended for **repeatable, pre-warmed workspaces**.

Use cases:

- A “multi-repo workspace” folder that includes multiple git repos plus an `AGENTS.md` describing how they relate.
- Pre-cached build artifacts (`node_modules`, `.build`, etc.) to reduce setup time.
- A startup script that refreshes repos or performs additional configuration in the copied workspace.

## Configuration

Both `server.yml` and `runner.yml` support:

- `workspaces_path` (optional): where Wuhu creates per-session workspaces.
  - Default: `~/.wuhu/workspaces`
- `environments[].type: folder-template`
- `environments[].path`: the template folder to copy from
- `environments[].startup_script` (optional): a script path executed **in the copied workspace**

Example:

```yaml
workspaces_path: ~/.wuhu/workspaces
environments:
  - name: multi-repo
    type: folder-template
    path: /Users/alice/Templates/multi-repo
    startup_script: ./startup.sh
```

`startup_script` is resolved like this:

- Absolute paths run as-is.
- Relative paths are resolved relative to the copied workspace root.

## Behavior

At session creation time:

1. Wuhu copies the template directory to `workspaces_path/<session-id>` (or `-N` if that path already exists).
2. If `startup_script` is set, Wuhu executes it with `bash` in the copied workspace directory.
3. The session’s working directory (`WuhuSession.cwd`) is the copied workspace path.

For **runner sessions**, the runner performs the copy+startup and returns the resolved environment snapshot to the server.

## Persistence

Wuhu stores an immutable environment snapshot in both databases (server sessions DB and runner `runner_sessions` DB):

- `environment.type = folder-template`
- `environment.path = <copied workspace path>`
- `environment.templatePath = <template folder path>`
- `environment.startupScript = <startup_script value, if set>`

This makes session execution reproducible even if config changes later.

## Implementation Notes

- The server includes `sessionID` in `resolve_environment_request` so a runner can create a session-specific workspace path.
- SQLite migrations add columns for the extra environment metadata (`templatePath`, `startupScript`) without rewriting existing data.

