# Runbook: Run `@wuhu/sandbox-daemon` inside a Modal Sandbox

Date: 2026-02-02

Goal: Build a Modal image (no Dockerfile) based on a public Node.js image,
install Pi Coding Agent first, install Deno and ensure it’s on `PATH`,
upload/bundle the `@wuhu/sandbox-daemon`, start it behind an **encrypted HTTPS
tunnel**, and talk to it using **our JWT** (not Modal connect tokens).

## Prereqs (local env)

Environment variables:

- `MODAL_TOKEN_ID` / `MODAL_TOKEN_SECRET` (Modal auth)
- `GH_TOKEN` (GitHub token) **or** `GITHUB_TOKEN` (optional; used for
  `/credentials`)
- `OPENAI_API_KEY` **or** `WUHU_DEV_OPENAI_API_KEY` (optional; used for
  `/credentials` and Pi)

Security note: **Never commit or paste token values into the repo.** This doc
includes _how_ to pass tokens, not their values.

## 1) Bundle the daemon (Deno)

From repo root:

```bash
deno --version

rm -f /tmp/sandbox-daemon.bundle.js
deno bundle --platform=deno \
  -o /tmp/sandbox-daemon.bundle.js \
  packages/sandbox-daemon/main.ts
```

Notes:

- `deno bundle` behavior is evolving (Deno 2.x). This worked with Deno `2.6.7`.
- The output is a single JS file with dependencies inlined, ready to `deno run`.

## 2) Create a Modal image via “dockerfile commands” (no Docker)

Modal’s TS SDK supports image layers via `Image.dockerfileCommands([...])`, then
building via `image.build(app)`.

We used a base public Node image:

- `node:22-bookworm-slim`

Then installed:

1. Pi Coding Agent (first, as requested):

```bash
npm install -g @mariozechner/pi-coding-agent@0.51.0
```

2. Deno (and ensured it’s on PATH):

```bash
curl -fsSL https://deno.land/install.sh | sh -s v2.6.7
export PATH=/root/.deno/bin:$PATH
```

Also installed `git` (needed for `/init` cloning) and a few basics.

## 3) Start a sandbox (1 hour auto-delete)

When creating the sandbox, set BOTH:

- `timeoutMs: 60 * 60 * 1000`
- `idleTimeoutMs: 60 * 60 * 1000`

This overrides Modal’s default short lifetime (5 minutes).

Expose the daemon port via encrypted tunnel:

- `encryptedPorts: [8787]`

## 4) Upload the bundled daemon into the sandbox

Use Modal sandbox filesystem API:

- `sb.open(path, "w")` then `write()` the bundle bytes

We uploaded to:

- `/root/wuhu-daemon/sandbox-daemon.bundle.js`

## 5) Start the daemon inside the sandbox (Deno)

Run:

```bash
deno run -A /root/wuhu-daemon/sandbox-daemon.bundle.js
```

Environment used:

- `SANDBOX_DAEMON_HOST=0.0.0.0`
- `SANDBOX_DAEMON_PORT=8787`
- `SANDBOX_DAEMON_WORKSPACE_ROOT=/root/workspace`
- `SANDBOX_DAEMON_JWT_ENABLED=true`
- `SANDBOX_DAEMON_JWT_SECRET=<random secret>`
- Optionally `OPENAI_API_KEY=<...>` (if you have it; daemon reads from env)

Pi usage notes:

- The daemon defaults to `SANDBOX_DAEMON_AGENT_MODE=pi-rpc` and expects `pi` on
  `PATH`.
- Installing Pi globally (`npm install -g ...`) makes `pi` available.

## 6) Get the tunnel URL and talk to the daemon (JWT, not Modal connect token)

Fetch tunnels:

- `const tunnels = await sb.tunnels()` then `tunnels[8787].url`

Use _our_ JWT:

- `POST /credentials` requires `scope: "control"`
- `POST /prompt`, `POST /init`, `POST /abort` require `scope: "control"`
- `GET /stream` allows `scope: "observer"` or `"control"`

Example curl (SSE):

```bash
curl -N \
  -H "Authorization: Bearer <OBSERVER_TOKEN>" \
  "https://<modal-host>/stream?cursor=0&follow=1"
```

Example curl (prompt):

```bash
curl -s -X POST \
  -H "Authorization: Bearer <CONTROL_TOKEN>" \
  -H "content-type: application/json" \
  -d '{"message":"hello from outside the sandbox"}' \
  "https://<modal-host>/prompt"
```

## 7) Passing the GitHub token (without exposing it)

We did **not** bake the GitHub token into the image.

Instead, we used `/credentials` and passed it as:

```json
{
  "version": "experiment",
  "github": { "token": "<GH_TOKEN>" }
}
```

Practical approach:

- Keep `GH_TOKEN` (or `GITHUB_TOKEN`) only in your local environment.
- In your launcher script, read it from `process.env.GH_TOKEN` and send it to
  the daemon via `POST /credentials`.
- The daemon converts it to env vars for Pi and git tooling (sets `GITHUB_TOKEN`
  inside the spawned Pi process).

## Repro script (Node.js + Modal SDK)

This is essentially what was run locally to build the image, start the sandbox,
upload the bundle, start the daemon, and print a curlable tunnel URL + JWTs.

```js
// save as: /tmp/run_wuhu_sandbox_daemon.mjs (or move into scripts/ locally)
import crypto from 'node:crypto'
import fs from 'node:fs/promises'
import process from 'node:process'
import { ModalClient } from 'modal'

function requireEnv(name) {
  const value = process.env[name]
  if (!value || !value.trim()) throw new Error(`Missing env var: ${name}`)
  return value
}

function base64url(input) {
  return Buffer.from(input)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '')
}

function signHs256Jwt(claims, secret) {
  const headerB64 = base64url(JSON.stringify({ alg: 'HS256', typ: 'JWT' }))
  const payloadB64 = base64url(JSON.stringify(claims))
  const signingInput = `${headerB64}.${payloadB64}`
  const sig = crypto.createHmac('sha256', secret).update(signingInput).digest()
  const sigB64 = Buffer.from(sig)
    .toString('base64')
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/g, '')
  return `${signingInput}.${sigB64}`
}

const modal = new ModalClient({
  tokenId: requireEnv('MODAL_TOKEN_ID'),
  tokenSecret: requireEnv('MODAL_TOKEN_SECRET'),
})

const openAiKey = process.env.OPENAI_API_KEY?.trim() ||
  process.env.WUHU_DEV_OPENAI_API_KEY?.trim() ||
  ''
const ghToken = process.env.GH_TOKEN?.trim() ||
  process.env.GITHUB_TOKEN?.trim() || ''

const bundleBytes = await fs.readFile('/tmp/sandbox-daemon.bundle.js')

const app = await modal.apps.fromName('wuhu-sandbox-daemon-experiment', {
  createIfMissing: true,
})

const PORT = 8787
const oneHour = 60 * 60 * 1000

let image = modal.images.fromRegistry('node:22-bookworm-slim')
image = image.dockerfileCommands([
  'RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git unzip && rm -rf /var/lib/apt/lists/*',
  'RUN npm install -g @mariozechner/pi-coding-agent@0.51.0',
  'RUN curl -fsSL https://deno.land/install.sh | sh -s v2.6.7',
  'ENV PATH=/root/.deno/bin:$PATH',
  'RUN deno --version',
  'RUN pi --version || true',
])

console.log('Building image...')
const builtImage = await image.build(app)
console.log('Image built:', builtImage.imageId)

console.log('Creating sandbox (1h idleTimeout + 1h timeout)...')
const sb = await modal.sandboxes.create(app, builtImage, {
  command: ['sleep', 'infinity'],
  encryptedPorts: [PORT],
  timeoutMs: oneHour,
  idleTimeoutMs: oneHour,
})

console.log('Sandbox ID:', sb.sandboxId)

await sb.exec(['mkdir', '-p', '/root/wuhu-daemon', '/root/workspace'])
const remoteBundlePath = '/root/wuhu-daemon/sandbox-daemon.bundle.js'
const f = await sb.open(remoteBundlePath, 'w')
await f.write(bundleBytes)
await f.flush()
await f.close()

const jwtSecret = crypto.randomBytes(32).toString('hex')
const now = Math.floor(Date.now() / 1000)
const controlToken = signHs256Jwt(
  { sub: 'wuhu', scope: 'control', exp: now + 55 * 60 },
  jwtSecret,
)
const observerToken = signHs256Jwt(
  { sub: 'wuhu', scope: 'observer', exp: now + 55 * 60 },
  jwtSecret,
)

await sb.exec(['deno', 'run', '-A', remoteBundlePath], {
  env: {
    SANDBOX_DAEMON_HOST: '0.0.0.0',
    SANDBOX_DAEMON_PORT: String(PORT),
    SANDBOX_DAEMON_WORKSPACE_ROOT: '/root/workspace',
    SANDBOX_DAEMON_JWT_ENABLED: 'true',
    SANDBOX_DAEMON_JWT_SECRET: jwtSecret,
    ...(openAiKey ? { OPENAI_API_KEY: openAiKey } : {}),
  },
})

const tunnels = await sb.tunnels(60_000)
const baseUrl = tunnels[PORT].url.replace(/\/$/, '')

console.log('Base URL:', baseUrl)
console.log('SSE:', `${baseUrl}/stream?cursor=0&follow=1`)
console.log('CONTROL_BEARER:', controlToken)
console.log('OBSERVER_BEARER:', observerToken)

// Optional: send credentials so Pi gets GitHub token.
if (ghToken || openAiKey) {
  await fetch(`${baseUrl}/credentials`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${controlToken}`,
    },
    body: JSON.stringify({
      version: 'experiment',
      llm: openAiKey ? { openaiApiKey: openAiKey } : undefined,
      github: ghToken ? { token: ghToken } : undefined,
    }),
  })
}
```

## Troubleshooting

- If you get no agent events: ensure `pi` is installed and on `PATH`, and that
  the daemon is in `pi-rpc` mode (default).
- If cloning fails in `/init`: ensure `git` is installed and (if private repos)
  that you set `github.token` via `/credentials`.
- If SSE returns 401/403: use the correct JWT token/scope; `/stream` needs
  `observer` or `control`, while POST endpoints need `control`.
