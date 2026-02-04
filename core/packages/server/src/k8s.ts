import { parse } from '@std/yaml'
import { decodeBase64 } from '@std/encoding/base64'
import { dirname, isAbsolute, join } from '@std/path'
import type { KubeConfigOptions } from './config.ts'

export interface KubeClient {
  namespace: string
  request: (path: string, init?: RequestInit) => Promise<Response>
}

interface KubeConfigFile {
  clusters?: Array<{
    name: string
    cluster: {
      server: string
      'certificate-authority'?: string
      'certificate-authority-data'?: string
      'insecure-skip-tls-verify'?: boolean
    }
  }>
  users?: Array<{
    name: string
    user: {
      token?: string
      username?: string
      password?: string
      'client-certificate-data'?: string
      'client-key-data'?: string
    }
  }>
  contexts?: Array<{
    name: string
    context: {
      cluster: string
      user: string
      namespace?: string
    }
  }>
  'current-context'?: string
}

interface KubeAuth {
  headers: Headers
  client?: Deno.HttpClient
}

function decodeBase64Text(value: string): string {
  const bytes = decodeBase64(value)
  return new TextDecoder().decode(bytes)
}

function resolvePath(baseDir: string, value: string): string {
  return isAbsolute(value) ? value : join(baseDir, value)
}

async function createInClusterClient(): Promise<KubeClient> {
  const host = Deno.env.get('KUBERNETES_SERVICE_HOST')
  if (!host) {
    throw new Error('KUBERNETES_SERVICE_HOST is not set')
  }
  const port = Deno.env.get('KUBERNETES_SERVICE_PORT') ?? '443'
  const baseUrl = `https://${host}:${port}`
  const token = await Deno.readTextFile(
    '/var/run/secrets/kubernetes.io/serviceaccount/token',
  )
  const ca = await Deno.readTextFile(
    '/var/run/secrets/kubernetes.io/serviceaccount/ca.crt',
  )
  let namespace = Deno.env.get('KUBE_NAMESPACE') ?? 'default'
  try {
    const ns = await Deno.readTextFile(
      '/var/run/secrets/kubernetes.io/serviceaccount/namespace',
    )
    if (ns.trim()) namespace = ns.trim()
  } catch {
    // ignore
  }

  const client = Deno.createHttpClient({ caCerts: [ca] })
  const headers = new Headers()
  headers.set('authorization', `Bearer ${token.trim()}`)

  return {
    namespace,
    request: (path, init = {}) =>
      fetch(`${baseUrl}${path}`, {
        ...init,
        headers: mergeHeaders(headers, init.headers),
        client,
      }),
  }
}

async function createAuthForKubeconfig(
  config: KubeConfigFile,
  options: KubeConfigOptions,
): Promise<{
  server: string
  namespace: string
  auth: KubeAuth
}> {
  const contextName = options.context ?? config['current-context']
  if (!contextName) {
    throw new Error('KUBECONFIG has no current-context')
  }
  const context = config.contexts?.find((item) => item.name === contextName)
  if (!context) {
    throw new Error(`KUBECONFIG context not found: ${contextName}`)
  }
  const cluster = config.clusters?.find(
    (item) => item.name === context.context.cluster,
  )
  if (!cluster) {
    throw new Error(`KUBECONFIG cluster not found: ${context.context.cluster}`)
  }
  const user = config.users?.find(
    (item) => item.name === context.context.user,
  )
  if (!user) {
    throw new Error(`KUBECONFIG user not found: ${context.context.user}`)
  }

  const headers = new Headers()
  let client: Deno.HttpClient | undefined

  if (user.user.token) {
    headers.set('authorization', `Bearer ${user.user.token}`)
  } else if (user.user.username && user.user.password) {
    const encoded = btoa(`${user.user.username}:${user.user.password}`)
    headers.set('authorization', `Basic ${encoded}`)
  }

  const baseDir = dirname(options.kubeconfigPath ?? '')
  const caCerts: string[] = []
  if (cluster.cluster['certificate-authority-data']) {
    caCerts.push(
      decodeBase64Text(cluster.cluster['certificate-authority-data']),
    )
  } else if (cluster.cluster['certificate-authority']) {
    const caPath = resolvePath(
      baseDir,
      cluster.cluster['certificate-authority'],
    )
    caCerts.push(await Deno.readTextFile(caPath))
  }

  let cert: string | undefined
  let key: string | undefined
  if (user.user['client-certificate-data']) {
    cert = decodeBase64Text(user.user['client-certificate-data'])
  }
  if (user.user['client-key-data']) {
    key = decodeBase64Text(user.user['client-key-data'])
  }

  if (caCerts.length || cert || key) {
    client = Deno.createHttpClient({
      caCerts: caCerts.length ? caCerts : undefined,
      cert,
      key,
    })
  }

  if (!headers.has('authorization') && !cert && !key) {
    throw new Error(
      'KUBECONFIG user auth missing (token or client certificate)',
    )
  }

  const namespace = context.context.namespace ??
    Deno.env.get('KUBE_NAMESPACE') ?? 'default'

  return {
    server: cluster.cluster.server.replace(/\/$/, ''),
    namespace,
    auth: { headers, client },
  }
}

function mergeHeaders(base: Headers, extra?: HeadersInit): Headers {
  const merged = new Headers(base)
  if (!extra) return merged
  const additions = new Headers(extra)
  for (const [key, value] of additions.entries()) {
    merged.set(key, value)
  }
  return merged
}

async function createKubeconfigClient(
  options: KubeConfigOptions,
): Promise<KubeClient> {
  const configPath = options.kubeconfigPath ??
    `${Deno.env.get('HOME') ?? ''}/.kube/config`
  const raw = await Deno.readTextFile(configPath)
  const parsed = parse(raw) as KubeConfigFile
  const { server, namespace, auth } = await createAuthForKubeconfig(parsed, {
    ...options,
    kubeconfigPath: configPath,
  })

  return {
    namespace,
    request: (path, init = {}) =>
      fetch(`${server}${path}`, {
        ...init,
        headers: mergeHeaders(auth.headers, init.headers),
        client: auth.client,
      }),
  }
}

export async function createKubeClient(
  options: KubeConfigOptions,
): Promise<KubeClient> {
  if (Deno.env.get('KUBERNETES_SERVICE_HOST')) {
    return await createInClusterClient()
  }
  return await createKubeconfigClient(options)
}

export interface SandboxJobConfig {
  id: string
  jobName: string
  namespace: string
  image: string
  daemonPort: number
  previewPort: number
}

export async function createSandboxJob(
  client: KubeClient,
  config: SandboxJobConfig,
): Promise<void> {
  const job = {
    apiVersion: 'batch/v1',
    kind: 'Job',
    metadata: {
      name: config.jobName,
      namespace: config.namespace,
      labels: {
        'wuhu.sandbox/id': config.id,
        'wuhu.sandbox/job': config.jobName,
      },
    },
    spec: {
      backoffLimit: 0,
      template: {
        metadata: {
          labels: {
            'wuhu.sandbox/id': config.id,
            'wuhu.sandbox/job': config.jobName,
          },
        },
        spec: {
          restartPolicy: 'Never',
          containers: [
            {
              name: 'sandbox',
              image: config.image,
              imagePullPolicy: 'IfNotPresent',
              command: ['deno'],
              args: ['run', '-A', 'packages/sandbox-daemon/main.ts'],
              securityContext: {
                runAsUser: 0,
                runAsGroup: 0,
              },
              env: [
                { name: 'SANDBOX_DAEMON_HOST', value: '0.0.0.0' },
                {
                  name: 'SANDBOX_DAEMON_PORT',
                  value: String(config.daemonPort),
                },
                { name: 'SANDBOX_DAEMON_AGENT_MODE', value: 'pi-rpc' },
                { name: 'SANDBOX_DAEMON_JWT_ENABLED', value: 'false' },
                { name: 'SANDBOX_DAEMON_WORKSPACE_ROOT', value: '/root' },
                { name: 'SANDBOX_DAEMON_PREVIEW_ROOT', value: '/root/repo' },
              ],
              ports: [
                { name: 'daemon', containerPort: config.daemonPort },
                { name: 'preview', containerPort: config.previewPort },
              ],
            },
          ],
        },
      },
    },
  }

  const response = await client.request(
    `/apis/batch/v1/namespaces/${config.namespace}/jobs`,
    {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(job),
    },
  )
  if (!response.ok) {
    const errorText = await response.text()
    throw new Error(
      `Failed to create job ${config.jobName}: ${response.status} ${errorText}`,
    )
  }
}

export async function deleteSandboxJob(
  client: KubeClient,
  namespace: string,
  jobName: string,
): Promise<void> {
  const response = await client.request(
    `/apis/batch/v1/namespaces/${namespace}/jobs/${jobName}`,
    { method: 'DELETE' },
  )
  if (!response.ok && response.status !== 404) {
    const errorText = await response.text()
    throw new Error(
      `Failed to delete job ${jobName}: ${response.status} ${errorText}`,
    )
  }
}

export interface KubePodSummary {
  name?: string
  ip?: string
  phase?: string
}

export async function findSandboxPod(
  client: KubeClient,
  namespace: string,
  sandboxId: string,
): Promise<KubePodSummary | undefined> {
  const selector = encodeURIComponent(`wuhu.sandbox/id=${sandboxId}`)
  const response = await client.request(
    `/api/v1/namespaces/${namespace}/pods?labelSelector=${selector}`,
  )
  if (!response.ok) {
    const errorText = await response.text()
    throw new Error(
      `Failed to list pods for sandbox ${sandboxId}: ${response.status} ${errorText}`,
    )
  }
  const data = await response.json()
  const items = (data?.items ?? []) as Array<{
    metadata?: { name?: string }
    status?: { podIP?: string; phase?: string }
  }>
  if (!items.length) return undefined
  const preferred = items.find((item) => item.status?.podIP) ?? items[0]
  return {
    name: preferred.metadata?.name,
    ip: preferred.status?.podIP,
    phase: preferred.status?.phase,
  }
}
