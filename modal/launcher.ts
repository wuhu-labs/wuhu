import path from 'node:path'
import posixPath from 'node:path/posix'
import fs from 'node:fs/promises'
import os from 'node:os'
import { spawn } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { webcrypto as crypto } from 'node:crypto'

import { ModalClient } from 'modal'

type ModalSandbox = Awaited<ReturnType<ModalClient['sandboxes']['create']>>

interface RunOptions {
  cwd?: string
  env?: Record<string, string>
}

function requireEnv(name: string): string {
  const value = process.env[name]
  if (!value || !value.trim()) {
    throw new Error(`Missing env var: ${name}`)
  }
  return value.trim()
}

async function run(cmd: string, args: string[], options: RunOptions = {}) {
  return new Promise<void>((resolve, reject) => {
    const child = spawn(cmd, args, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      stdio: 'inherit',
    })
    child.on('exit', (code) => {
      if (code === 0) resolve()
      else {reject(
          new Error(`${cmd} ${args.join(' ')} failed: ${code ?? 'null'}`),
        )}
    })
    child.on('error', reject)
  })
}

function randomHex(bytes: number): string {
  const buffer = new Uint8Array(bytes)
  crypto.getRandomValues(buffer)
  return Array.from(buffer, (b) => b.toString(16).padStart(2, '0')).join('')
}

function base64UrlEncodeBytes(bytes: Uint8Array): string {
  let binary = ''
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i])
  }
  const b64 = Buffer.from(binary, 'binary').toString('base64')
  return b64.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '')
}

async function hmacSha256(
  secret: string,
  message: string,
): Promise<Uint8Array> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const signature = await crypto.subtle.sign(
    'HMAC',
    key,
    new TextEncoder().encode(message),
  )
  return new Uint8Array(signature)
}

async function signHs256Jwt(
  claims: Record<string, unknown>,
  secret: string,
): Promise<string> {
  const headerB64 = base64UrlEncodeBytes(
    new TextEncoder().encode(JSON.stringify({ alg: 'HS256', typ: 'JWT' })),
  )
  const payloadB64 = base64UrlEncodeBytes(
    new TextEncoder().encode(JSON.stringify(claims)),
  )
  const signingInput = `${headerB64}.${payloadB64}`
  const signature = await hmacSha256(secret, signingInput)
  const signatureB64 = base64UrlEncodeBytes(signature)
  return `${signingInput}.${signatureB64}`
}

async function uploadFile(
  sb: ModalSandbox,
  remotePath: string,
  bytes: Uint8Array,
) {
  const file = await sb.open(remotePath, 'w')
  await file.write(bytes)
  await file.flush()
  await file.close()
}

async function uploadDir(
  sb: ModalSandbox,
  localDir: string,
  remoteDir: string,
) {
  await sb.exec(['mkdir', '-p', remoteDir])
  const entries = await fs.readdir(localDir, { withFileTypes: true })
  for (const entry of entries) {
    const localPath = path.join(localDir, entry.name)
    const remotePath = posixPath.join(remoteDir, entry.name)
    if (entry.isDirectory()) {
      await uploadDir(sb, localPath, remotePath)
      continue
    }
    const bytes = await fs.readFile(localPath)
    await uploadFile(sb, remotePath, bytes)
  }
}

async function makeTempFile(prefix: string, suffix: string): Promise<string> {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), prefix))
  return path.join(dir, `file${suffix}`)
}

async function sleep(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms))
}

async function main() {
  const scriptDir = path.dirname(fileURLToPath(import.meta.url))
  const repoRoot = path.dirname(scriptDir)
  const uiRoot = path.join(repoRoot, 'frontend', 'sandbox-daemon-ui')
  const daemonEntry = path.join(
    repoRoot,
    'packages',
    'sandbox-daemon',
    'main.ts',
  )
  const bundlePath = await makeTempFile('sandbox-daemon-', '.bundle.js')

  const daemonPort = Number(process.env['SANDBOX_DAEMON_PORT'] || 8787)
  const uiPort = Number(process.env['SANDBOX_DAEMON_UI_PORT'] || 4173)
  const appName = process.env['SANDBOX_DAEMON_MODAL_APP'] ||
    'wuhu-sandbox-daemon-debug'
  const oneHour = 60 * 60 * 1000

  console.log('Bundling sandbox daemon...')
  // Run bundling from the repo root so Deno picks up the root workspace
  // config instead of treating this package.json as a separate workspace.
  await run('deno', ['bundle', '-o', bundlePath, daemonEntry], {
    cwd: repoRoot,
  })

  console.log('Building sandbox daemon UI...')
  await run('bun', ['install'], { cwd: uiRoot })
  await run('bun', ['run', 'build'], { cwd: uiRoot })

  const uiDist = path.join(uiRoot, 'dist')
  const bundleBytes = await fs.readFile(bundlePath)

  const modal = new ModalClient({
    tokenId: requireEnv('MODAL_TOKEN_ID'),
    tokenSecret: requireEnv('MODAL_TOKEN_SECRET'),
  })

  const openAiKey = process.env['OPENAI_API_KEY']?.trim() ||
    process.env['WUHU_DEV_OPENAI_API_KEY']?.trim() ||
    ''
  const ghToken = process.env['GH_TOKEN']?.trim() ||
    process.env['GITHUB_TOKEN']?.trim() ||
    ''

  const app = await modal.apps.fromName(appName, { createIfMissing: true })
  let image = modal.images.fromRegistry('node:22-bookworm-slim')
  image = image.dockerfileCommands([
    'RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates git unzip && rm -rf /var/lib/apt/lists/*',
    'RUN npm install -g @mariozechner/pi-coding-agent@0.51.0',
    'RUN curl -fsSL https://deno.land/install.sh | sh -s v2.6.7',
    'RUN ln -s /root/.deno/bin/deno /usr/local/bin/deno',
    'RUN deno --version',
    'RUN pi --version || true',
  ])

  console.log('Building Modal image...')
  const builtImage = await image.build(app)
  console.log('Image built:', builtImage.imageId)

  console.log('Creating sandbox (1h idle + 1h timeout)...')
  const sb = await modal.sandboxes.create(app, builtImage, {
    command: ['sleep', 'infinity'],
    encryptedPorts: [daemonPort, uiPort],
    timeoutMs: oneHour,
    idleTimeoutMs: oneHour,
  })

  console.log('Sandbox ID:', sb.sandboxId)
  console.log('Preparing sandbox filesystem and uploads...')

  await sb.exec(['mkdir', '-p', '/root/wuhu-daemon', '/root/workspace'])
  await sb.exec(['mkdir', '-p', '/root/wuhu-ui/dist'])

  const remoteBundlePath = '/root/wuhu-daemon/sandbox-daemon.bundle.js'
  await uploadFile(sb, remoteBundlePath, bundleBytes)

  const serverScript = `import http from 'node:http'
import { createReadStream, statSync } from 'node:fs'
import { extname, join } from 'node:path'

const root = process.env.STATIC_ROOT || '/root/wuhu-ui/dist'
const port = Number(process.env.PORT || 4173)

const mime = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.ico': 'image/x-icon',
}

function sendFile(res, filePath) {
  const ext = extname(filePath)
  res.setHeader('content-type', mime[ext] || 'application/octet-stream')
  res.setHeader('cache-control', 'no-store')
  createReadStream(filePath).pipe(res)
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url || '/', 'http://localhost')
  let pathname = decodeURIComponent(url.pathname)
  if (pathname === '/') pathname = '/index.html'

  let filePath = join(root, pathname)
  try {
    const stat = statSync(filePath)
    if (stat.isDirectory()) {
      filePath = join(filePath, 'index.html')
    }
    return sendFile(res, filePath)
  } catch {
    const fallback = join(root, 'index.html')
    try {
      return sendFile(res, fallback)
    } catch {
      res.statusCode = 404
      res.end('Not found')
    }
  }
})

server.listen(port, '0.0.0.0', () => {
  console.log('UI server listening on', port)
})
`

  await uploadDir(sb, uiDist, '/root/wuhu-ui/dist')
  await uploadFile(
    sb,
    '/root/wuhu-ui/server.mjs',
    new TextEncoder().encode(serverScript),
  )

  const jwtEnabled = process.env['SANDBOX_DAEMON_JWT_ENABLED'] === 'true' ||
    Boolean(process.env['SANDBOX_DAEMON_JWT_SECRET'])
  const jwtSecret = jwtEnabled
    ? process.env['SANDBOX_DAEMON_JWT_SECRET'] || randomHex(32)
    : null
  const jwtIssuer = process.env['SANDBOX_DAEMON_JWT_ISSUER']
  const now = Math.floor(Date.now() / 1000)
  const exp = now + 55 * 60

  const adminToken = jwtEnabled
    ? await signHs256Jwt(
      {
        sub: 'wuhu',
        scope: 'admin',
        exp,
        ...(jwtIssuer ? { iss: jwtIssuer } : {}),
      },
      jwtSecret!,
    )
    : null
  const userToken = jwtEnabled
    ? await signHs256Jwt(
      {
        sub: 'wuhu',
        scope: 'user',
        exp,
        ...(jwtIssuer ? { iss: jwtIssuer } : {}),
      },
      jwtSecret!,
    )
    : null

  // Start daemon and UI as background processes inside the sandbox.
  await sb.exec(
    [
      'sh',
      '-lc',
      'deno run -A /root/wuhu-daemon/sandbox-daemon.bundle.js > /root/wuhu-daemon/daemon.log 2>&1 &',
    ],
    {
      env: {
        SANDBOX_DAEMON_HOST: '0.0.0.0',
        SANDBOX_DAEMON_PORT: String(daemonPort),
        SANDBOX_DAEMON_WORKSPACE_ROOT: '/root/workspace',
        SANDBOX_DAEMON_JWT_ENABLED: jwtEnabled ? 'true' : 'false',
        ...(jwtEnabled ? { SANDBOX_DAEMON_JWT_SECRET: jwtSecret! } : {}),
        ...(jwtIssuer ? { SANDBOX_DAEMON_JWT_ISSUER: jwtIssuer } : {}),
        ...(openAiKey ? { OPENAI_API_KEY: openAiKey } : {}),
      },
    },
  )

  await sb.exec(
    [
      'sh',
      '-lc',
      'node /root/wuhu-ui/server.mjs > /root/wuhu-ui/ui.log 2>&1 &',
    ],
    {
      env: {
        PORT: String(uiPort),
        STATIC_ROOT: '/root/wuhu-ui/dist',
      },
    },
  )

  console.log('Waiting for tunnels to become available...')
  const tunnels = await sb.tunnels(60_000)
  const daemonUrl = tunnels[daemonPort].url.replace(/\/$/, '')
  const uiUrl = tunnels[uiPort].url.replace(/\/$/, '')
  const uiOrigin = new URL(uiUrl).origin
  console.log('Resolved tunnel URLs:', { daemonUrl, uiUrl })

  const initHeaders: HeadersInit = {
    'content-type': 'application/json',
    ...(adminToken ? { authorization: `Bearer ${adminToken}` } : {}),
  }

  console.log('Probing daemon /init endpoint...')
  let initOk = false
  for (let attempt = 1; attempt <= 3 && !initOk; attempt++) {
    try {
      console.log(`  Init attempt ${attempt}...`)
      const initRes = await fetch(`${daemonUrl}/init`, {
        method: 'POST',
        headers: initHeaders,
        body: JSON.stringify({
          workspace: { repos: [] },
          cors: { allowedOrigins: [uiOrigin] },
        }),
      })
      if (!initRes.ok) {
        console.error(
          `  Init failed (attempt ${attempt}):`,
          initRes.status,
          await initRes.text(),
        )
      } else {
        initOk = true
        console.log('  Init succeeded')
        break
      }
    } catch (err) {
      console.error(`  Init error (attempt ${attempt}):`, err)
    }
    if (!initOk && attempt < 3) {
      console.log('  Waiting 10s before retrying init...')
      await sleep(10_000)
    }
  }

  if (!initOk) {
    console.error('Daemon /init did not succeed after 3 attempts')
  }

  if (jwtEnabled && (ghToken || openAiKey)) {
    await fetch(`${daemonUrl}/credentials`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${adminToken}`,
      },
      body: JSON.stringify({
        version: 'modal-debug',
        llm: openAiKey ? { openaiApiKey: openAiKey } : undefined,
        github: ghToken ? { token: ghToken } : undefined,
      }),
    })
  }

  console.log('\n========================================')
  console.log('Sandbox daemon ready')
  console.log('========================================\n')
  console.log('Daemon URL:', daemonUrl)
  console.log('UI URL:', uiUrl)
  if (jwtEnabled) {
    console.log('ADMIN_BEARER:', adminToken)
    console.log('USER_BEARER:', userToken)
  }

  modal.close()
}

// Run if invoked directly
main()
  .then(() => {
    process.exit(0)
  })
  .catch((err) => {
    console.error(err)
    process.exit(1)
  })
