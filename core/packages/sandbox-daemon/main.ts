import { createSandboxDaemonApp } from './src/server.ts'
import { type AgentProvider, FakeAgentProvider } from './src/agent-provider.ts'
import { PiAgentProvider } from './src/pi-agent-provider.ts'
import {
  applyCredentialsToEnv,
  InMemoryCredentialsStore,
} from './src/credentials.ts'
import { LazyAgentProvider } from './src/lazy-agent-provider.ts'
import { loadSandboxDaemonConfig } from './src/config.ts'
import { readEnvTrimmed } from './src/env.ts'
import { serveDir } from '@std/http/file-server'
import { dirname, join } from '@std/path'

function fileExists(path: string): boolean {
  try {
    const stat = Deno.statSync(path)
    return stat.isFile
  } catch {
    return false
  }
}

function findOnPath(command: string): string | undefined {
  if (command.includes('/')) {
    return fileExists(command) ? command : undefined
  }
  const pathEnv = Deno.env.get('PATH')
  if (!pathEnv) return undefined
  for (const dir of pathEnv.split(':')) {
    const candidate = `${dir}/${command}`
    if (fileExists(candidate)) return candidate
  }
  return undefined
}

const SESSION_STATE_PATH = '/root/.wuhu/pi-session.json'

interface StoredSessionState {
  sessionFile?: string
}

function loadStoredSessionState(): StoredSessionState | null {
  try {
    const raw = Deno.readTextFileSync(SESSION_STATE_PATH)
    const parsed = JSON.parse(raw)
    if (parsed && typeof parsed === 'object') {
      const sessionFile = typeof parsed.sessionFile === 'string'
        ? parsed.sessionFile
        : undefined
      if (sessionFile) {
        try {
          const stat = Deno.statSync(sessionFile)
          if (stat.isFile) {
            return { sessionFile }
          }
        } catch {
          // ignore missing session file
        }
      }
    }
  } catch {
    // ignore missing/invalid state
  }
  return null
}

function saveStoredSessionState(state: StoredSessionState): void {
  try {
    Deno.mkdirSync(dirname(SESSION_STATE_PATH), { recursive: true })
    Deno.writeTextFileSync(SESSION_STATE_PATH, JSON.stringify(state, null, 2))
  } catch {
    // ignore write errors
  }
}

function removeArg(args: string[], flag: string): string[] {
  const next: string[] = []
  let skipNext = false
  for (const arg of args) {
    if (skipNext) {
      skipNext = false
      continue
    }
    if (arg === flag) {
      if (flag === '--session') {
        skipNext = true
      }
      continue
    }
    next.push(arg)
  }
  return next
}

function resolvePiArgs(
  baseArgs: string[] | undefined,
  sessionFile?: string,
): string[] | undefined {
  let args = baseArgs && baseArgs.length ? [...baseArgs] : undefined
  if (sessionFile) {
    if (!args) {
      args = ['--mode', 'rpc', '--session', sessionFile]
    } else {
      args = removeArg(args, '--no-session')
      if (!args.includes('--session')) {
        args.push('--session', sessionFile)
      }
    }
  }
  return args
}

function resolvePiInvocation(
  config: { command?: string; args?: string[] },
  sessionFile?: string,
): {
  command: string
  args?: string[]
} {
  if (config.command) {
    return {
      command: config.command,
      args: resolvePiArgs(config.args, sessionFile),
    }
  }

  const onPath = findOnPath('pi')
  if (onPath) {
    return { command: 'pi', args: resolvePiArgs(config.args, sessionFile) }
  }

  // Developer fallback: run a locally-built pi CLI from ../pi-mono if present.
  const localPiCli = new URL(
    '../pi-mono/packages/coding-agent/dist/cli.js',
    import.meta.url,
  )
  const localPath = localPiCli.pathname
  if (fileExists(localPath)) {
    const resolvedArgs = resolvePiArgs(config.args, sessionFile) ??
      ['--mode', 'rpc']
    return {
      command: 'node',
      args: [localPath, ...resolvedArgs],
    }
  }

  return { command: 'pi', args: resolvePiArgs(config.args, sessionFile) }
}

const config = loadSandboxDaemonConfig()
const hostname = config.host
const port = config.port
const agentMode = config.agentMode
const previewRoot = Deno.env.get('SANDBOX_DAEMON_PREVIEW_ROOT') ??
  (config.workspaceRoot ? join(config.workspaceRoot, 'repo') : '/root/repo')

const credentials = new InMemoryCredentialsStore()

const envOpenAiKey = readEnvTrimmed('OPENAI_API_KEY') ??
  readEnvTrimmed('WUHU_DEV_OPENAI_API_KEY')
const envAnthropicKey = readEnvTrimmed('ANTHROPIC_API_KEY')

if (envOpenAiKey || envAnthropicKey) {
  credentials.set({
    version: 'env',
    llm: {
      openaiApiKey: envOpenAiKey,
      anthropicApiKey: envAnthropicKey,
    },
  })
}

const provider: AgentProvider = agentMode === 'mock'
  ? new FakeAgentProvider()
  : new LazyAgentProvider({
    getRevision: () => credentials.get().revision,
    create: () => {
      const snapshot = credentials.get()
      const sessionFile = loadStoredSessionState()?.sessionFile
      const { command, args } = resolvePiInvocation(config.pi, sessionFile)
      const cwd = config.pi.cwd
      return new PiAgentProvider({
        command,
        args,
        cwd,
        env: snapshot.env,
      })
    },
  })

const previewPort = 8066
const servers: { main?: Deno.HttpServer; preview?: Deno.HttpServer } = {}
let shuttingDown = false

const shutdown = async () => {
  if (shuttingDown) return
  shuttingDown = true
  try {
    await provider.stop()
  } catch {
    // ignore
  }
  try {
    await Deno.writeTextFile('/tmp/shutdown', new Date().toISOString())
  } catch {
    // ignore
  }
  try {
    servers.preview?.shutdown()
  } catch {
    // ignore
  }
  try {
    servers.main?.shutdown()
  } catch {
    // ignore
  }
}

const { app } = createSandboxDaemonApp({
  provider,
  onCredentials: async (payload) => {
    const hasOpenAi = Boolean(payload.llm?.openaiApiKey)
    const hasAnthropic = Boolean(payload.llm?.anthropicApiKey)
    console.log(
      `sandbox-daemon credentials received (openai=${hasOpenAi} anthropic=${hasAnthropic})`,
    )
    applyCredentialsToEnv(payload)
    credentials.set(payload)
    try {
      await provider.start()
      await persistSessionFile(provider)
    } catch (error) {
      console.error(
        'sandbox-daemon: failed to restart provider after credentials',
        error,
      )
    }
  },
  auth: config.jwt.enabled
    ? { secret: config.jwt.secret, issuer: config.jwt.issuer, enabled: true }
    : { enabled: false },
  workspaceRoot: config.workspaceRoot,
  onShutdown: shutdown,
})

async function persistSessionFile(providerInstance: AgentProvider) {
  if (!providerInstance.getState) return
  try {
    const state = await providerInstance.getState()
    const sessionFile = state?.sessionFile ?? null
    if (!sessionFile) return
    const stored = loadStoredSessionState()?.sessionFile
    if (stored === sessionFile) return
    saveStoredSessionState({ sessionFile })
  } catch {
    // ignore persistence errors
  }
}

try {
  await provider.start()
  await persistSessionFile(provider)
} catch {
  console.error(
    'sandbox-daemon: agent provider failed to start (install `pi` or set SANDBOX_DAEMON_AGENT_MODE=mock)',
  )
}

servers.preview = Deno.serve({
  hostname: '0.0.0.0',
  port: previewPort,
}, async (request) => {
  try {
    const stat = await Deno.stat(previewRoot)
    if (!stat.isDirectory) {
      throw new Error('preview_root_not_directory')
    }
    return await serveDir(request, {
      fsRoot: previewRoot,
      showDirListing: true,
    })
  } catch {
    return new Response(
      `<html><body style="font-family:system-ui;padding:2rem"><h1>Wuhu Sandbox Preview</h1><p>Repo not ready at ${previewRoot}.</p></body></html>`,
      { headers: { 'content-type': 'text/html; charset=utf-8' } },
    )
  }
})

servers.main = Deno.serve({ hostname, port }, app.fetch)

try {
  Deno.addSignalListener('SIGINT', () => void shutdown())
  Deno.addSignalListener('SIGTERM', () => void shutdown())
} catch {
  // Signal listeners may not be available in all environments.
}

console.log(
  `sandbox-daemon listening on http://${hostname}:${port} (agent=${agentMode})`,
)
console.log(`preview server listening on http://0.0.0.0:${previewPort}`)
console.log(`preview root: ${previewRoot}`)
console.log(
  `credentials loaded from env: OPENAI_API_KEY=${
    Boolean(envOpenAiKey)
  } ANTHROPIC_API_KEY=${Boolean(envAnthropicKey)}`,
)

if (servers.main) {
  await servers.main.finished
}
