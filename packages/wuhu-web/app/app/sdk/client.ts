import { authHeaders } from './auth'
import { api, inGroup, post } from './http'
import type { ViewerCache, ViewerCaches } from './open-cache'
import type {
  Entry,
  GroupSummary,
  ListOutput,
  ReadOutput,
  ServerInfo,
  SyncOutput,
  WriteOutput,
} from '~/lib/contract.gen'
import { sharedGroup } from '~/lib/shell-sdk/open-cache.js'

// What every group of one space shares: discovery, and one client per group.
export class SpaceServer {
  private infoPromise: Promise<ServerInfo> | undefined
  private readonly clients = new Map<string, SpaceClient>()

  constructor(private readonly caches: ViewerCaches | null = null) {}

  client(group: string): SpaceClient {
    let client = this.clients.get(group)
    if (client === undefined) {
      client = new SpaceClient(group, this, this.caches?.of(group) ?? null)
      this.clients.set(group, client)
    }
    return client
  }

  info(): Promise<ServerInfo> {
    this.infoPromise ??= this.kept<ServerInfo>(
      'server',
      () => api('/v1/server'),
    ).catch(
      (failure: unknown) => {
        this.infoPromise = undefined
        throw failure
      },
    )
    return this.infoPromise
  }

  // The feeds paint the kept list themselves; keeping it here also tells
  // forgetViewer which groups to purge.
  async groups(): Promise<GroupSummary[]> {
    const groups = await api<GroupSummary[]>('/v1/groups')
    void this.caches?.of(sharedGroup).put('meta', 'groups', groups)
    return groups
  }

  // Offline, the last answer still names the content origin, whose worker
  // paints the pages it kept.
  private async kept<Value>(
    key: string,
    fetch: () => Promise<Value>,
  ): Promise<Value> {
    const cache = this.caches?.of(sharedGroup)
    try {
      const value = await fetch()
      void cache?.put('meta', key, value)
      return value
    } catch (failure) {
      const kept = await cache?.get<Value>('meta', key)
      if (kept === undefined) throw failure
      return kept
    }
  }
}

// Every group's pages, shared's included, live on
// `https://<group>.<contentBase>`; null for a serve with no content plane.
function contentOriginOf(
  info: ServerInfo,
  group: string,
): string | null {
  if (info.contentBase != null) {
    return new URL(`https://${group}.${info.contentBase}`).origin
  }
  return legacyContentOrigin(info, group)
}

// Transitional, for a server that predates contentBase: pages on webOrigin,
// else on the API host at webPort, and a group other than shared on
// `<group>.<that host>`.
function legacyContentOrigin(info: ServerInfo, group: string): string | null {
  let url: URL
  if (info.webOrigin != null) {
    url = new URL(info.webOrigin)
  } else if (info.webPort != null) {
    url = new URL(globalThis.location.origin)
    url.port = String(info.webPort)
  } else {
    return null
  }
  if (group !== sharedGroup) url.hostname = `${group}.${url.hostname}`
  return url.origin
}

// One group of a space: its tools act in that group, and its pages live on
// that group's content origin.
export class SpaceClient {
  private contentSession: Promise<void> | undefined
  private reminting: Promise<string | null> | undefined

  constructor(
    readonly group: string,
    readonly server: SpaceServer,
    private readonly cache: ViewerCache | null,
  ) {}

  private async origin(): Promise<string | null> {
    return contentOriginOf(await this.server.info(), this.group)
  }

  // Only a minted read cookie is remembered. Offline, or with the space out
  // of reach (server down, off the LAN or VPN), there is nothing to mint: the
  // origin still paints what its page worker kept, and the next `online` or
  // refused content read mints again. Only an HTTP refusal throws; fetch
  // cannot tell CORS or TLS failures from unreachable, and painting wins.
  async contentOrigin(): Promise<string | null> {
    const origin = await this.origin()
    if (origin == null) return null
    if (globalThis.navigator?.onLine === false) return origin
    if (this.contentSession === undefined) {
      const minting: Promise<void> = this.mintContentSession(origin).then(
        (reached) => {
          if (!reached && this.contentSession === minting) {
            this.contentSession = undefined
          }
        },
        (failure: unknown) => {
          if (this.contentSession === minting) this.contentSession = undefined
          throw failure
        },
      )
      this.contentSession = minting
    }
    await this.contentSession
    return origin
  }

  // After the content origin refused its cookie, or the browser came back
  // online; callers while one is in flight share it.
  readonly remintContentSession = (): Promise<string | null> => {
    if (this.reminting === undefined) {
      this.contentSession = undefined
      this.reminting = this.contentOrigin().finally(() => {
        this.reminting = undefined
      })
    }
    return this.reminting
  }

  // False when the request never reached the server.
  private async mintContentSession(origin: string): Promise<boolean> {
    const headers = await authHeaders()
    let response: Response
    try {
      response = await fetch(`${origin}/_/session`, {
        method: 'POST',
        credentials: 'include',
        headers,
      })
    } catch {
      return false
    }
    if (!response.ok) {
      throw new Error(
        `content session bootstrap failed: HTTP ${response.status}`,
      )
    }
    return true
  }

  ls(path: string, hidden = false): Promise<ListOutput> {
    return this.tool('ls', hidden ? { path, hidden } : { path })
  }

  stat(path: string): Promise<Entry> {
    return this.tool('stat', { path })
  }

  async read(path: string): Promise<ReadOutput> {
    const output = await this.tool<ReadOutput>('read', { path })
    void this.cache?.put('document', path, output)
    return output
  }

  // The copy the last read left, if any.
  async keptRead(path: string): Promise<ReadOutput> {
    const kept = await this.cache?.get<ReadOutput>('document', path)
    if (kept === undefined) throw new Error(`${path} was never read here`)
    return kept
  }

  sync(path: string, baseToken: string, content: string): Promise<SyncOutput> {
    return this.tool('sync', { path, baseToken, content })
  }

  write(path: string, content: string): Promise<WriteOutput> {
    return this.tool('write', { path, content })
  }

  observeURL(glob: string, from: number): string {
    const params = new URLSearchParams({ glob, from: String(from) })
    return `/v1/observe?${params}`
  }

  private tool<Output>(name: string, input: unknown): Promise<Output> {
    return post(`/v1/tools/${name}`, input, inGroup(this.group))
  }
}
