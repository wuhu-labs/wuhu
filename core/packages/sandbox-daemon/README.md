# `@wuhu/sandbox-daemon`

HTTP daemon that wraps a coding agent (Pi in Protocol 0 RPC mode) behind a small
admin API and an SSE event stream.

## Run

```bash
deno run -A packages/sandbox-daemon/main.ts
```

### Common environment variables

- `OPENAI_API_KEY` (preferred) or `WUHU_DEV_OPENAI_API_KEY` (trimmed fallback)
- `SANDBOX_DAEMON_HOST` (default: `127.0.0.1`)
- `SANDBOX_DAEMON_PORT` (default: `8787`)
- `SANDBOX_DAEMON_AGENT_MODE` (`pi-rpc` or `mock`, default: `pi-rpc`)
- `SANDBOX_DAEMON_WORKSPACE_ROOT` (optional; base dir for repo paths in `/init`)

### Pi invocation

- `SANDBOX_DAEMON_PI_COMMAND` (default: `pi` if found on `PATH`)
- `SANDBOX_DAEMON_PI_ARGS` (optional; JSON array or whitespace-separated string)
- `SANDBOX_DAEMON_PI_CWD` (optional)

Example without a global `pi` install:

```bash
export SANDBOX_DAEMON_PI_COMMAND=npx
export SANDBOX_DAEMON_PI_ARGS='-y @mariozechner/pi-coding-agent --mode rpc --no-session'
```

### JWT auth (optional)

- `SANDBOX_DAEMON_JWT_ENABLED` (`true`/`false`, default: `true` if secret is
  set)
- `SANDBOX_DAEMON_JWT_SECRET` (HS256 secret)
- `SANDBOX_DAEMON_JWT_ISSUER` (optional)

When enabled:

- `admin` scope can call everything
- `user` scope can call `/prompt`, `/abort`, and `/stream`

To allow browser access from arbitrary domains, include a CORS allowlist in the
`/init` handshake:

```json
{
  "cors": {
    "allowedOrigins": ["https://your-ui.example"]
  }
}
```

## API

- `GET /health` → `{ ok: true }`
- `POST /credentials` → accepts `SandboxDaemonCredentialsPayload`, returns
  `{ ok: true }`
- `POST /init` → clones/checks out repos into `SANDBOX_DAEMON_WORKSPACE_ROOT`,
  returns repo summaries
- `POST /prompt` → forwards to agent, returns
  `{ success: true, command: "prompt" }`
- `POST /abort` → forwards to agent, returns
  `{ success: true, command: "abort" }`
- `GET /stream?cursor=0&follow=1` → SSE stream of `{ cursor, event }` envelopes

Example:

```bash
curl -X POST http://127.0.0.1:8787/prompt \
  -H 'content-type: application/json' \
  -d '{"message":"hello"}'

curl -N http://127.0.0.1:8787/stream?cursor=0&follow=1
```
