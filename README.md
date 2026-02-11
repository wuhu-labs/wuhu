# wuhu (Swift)

Swift 6.2 pivot of Wuhu.

## CLI

```bash
swift run wuhu --help

# Create a persisted session (prints session id)
swift run wuhu create-session --provider openai

# Send a prompt to an existing session (streams assistant output)
swift run wuhu prompt --session-id <session-id> "What's the weather in Tokyo?"

# Retrieve full transcript
swift run wuhu get-session --session-id <session-id>

# List sessions
swift run wuhu list-sessions
```

The CLI reads `OPENAI_API_KEY` / `ANTHROPIC_API_KEY` from the environment and will also load a local `.env` if present.

Client identity:

- `wuhu client prompt` sends an optional `user` (username) with each prompt.
- Configure via `WUHU_USERNAME` or `~/.wuhu/client.yml` `username:` (defaults to `<osuser>@<hostname>`).

Environments (from `~/.wuhu/server.yml` / `~/.wuhu/runner.yml`):

- `local`: use a fixed working directory (`path`).
- `folder-template`: copy a template folder (`path`) into `workspaces_path/<session-id>` and optionally run `startup_script` in the copied workspace.

Networking defaults:

- Server listens on `host`/`port` from `~/.wuhu/server.yml` (default: `127.0.0.1:5530`).
- Runner listens on `listen.host`/`listen.port` from `~/.wuhu/runner.yml` when `connectTo` is not set (default: `127.0.0.1:5531`).
