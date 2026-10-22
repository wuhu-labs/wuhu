import { kept } from '~/lib/cached-then-live'
import { coalescedRefresh } from './coalesced-refresh'
import type { Observation } from './observation'
import { isFileRefusal } from './errors'
import type { RevisionEvents } from '~/lib/contract.gen'
import { api, inGroup, post, withAssertion } from './http'
import type { ViewerCache, ViewerCaches } from './open-cache'
import type {
  GroupSummary,
  ListOutput,
  ReadOutput,
  ServerInfo,
  StatOutput,
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
// `https://<group>.<contentBase>`; null from a server that predates contentBase.
function contentOriginOf(
  info: ServerInfo,
  group: string,
): string | null {
  if (info.contentHost != null) {
    return new URL(`https://${info.contentHost.replace('{group}', group)}`)
      .origin
  }
  if (info.contentBase == null) return null
  return new URL(`https://${group}.${info.contentBase}`).origin
}

// One group of a space: its tools act in that group, and its pages live on
// that group's content origin.
export class SpaceClient {
  private readonly fileListeners = new Set<
    (event: RevisionEvents | null) => void
  >()

  readonly filesChanged = (event: RevisionEvents): void => {
    for (const listener of this.fileListeners) listener(event)
  }

  readonly filesConnected = (): void => {
    for (const listener of this.fileListeners) listener(null)
  }

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
    let reached = true
    const response = await withAssertion((headers) =>
      fetch(`${origin}/_/session`, {
        method: 'POST',
        credentials: 'include',
        headers,
      }).catch(() => {
        reached = false
        return Response.error()
      })
    )
    if (!reached) return false
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

  stat(path: string): Observation<StatOutput> {
    return this.observeFile(
      'meta',
      `stat:${path}`,
      path,
      () => this.tool<StatOutput>('stat', { path }),
    )
  }

  // A folder's entries, again whenever something under it changes.
  list(path: string): Observation<ListOutput> {
    return this.observeFile(
      'meta',
      `ls:${path}`,
      path,
      () => this.ls(path),
      true,
    )
  }

  read(path: string): Observation<ReadOutput> {
    return this.observeFile(
      'document',
      path,
      path,
      () => this.tool<ReadOutput>('read', { path }),
    )
  }

  private observeFile<Value>(
    kind: 'meta' | 'document',
    key: string,
    path: string,
    load: () => Promise<Value>,
    // A listing also changes with what is under it.
    listing = false,
  ): Observation<Value> {
    return (receive, failed) => {
      let closed = false
      let previous: string | undefined
      let retry = false
      const paint = (value: Value) => {
        if (closed) return
        const encoded = JSON.stringify(value)
        if (encoded !== previous) {
          previous = encoded
          receive(value)
        }
      }
      const refresh = coalescedRefresh(async () => {
        const value = await load()
        await this.cache?.put(kind, key, value).catch(() => undefined)
        return value
      }, (value) => {
        retry = false
        paint(value)
      }, (error) => {
        retry = !isFileRefusal(error)
        if (previous === undefined || !retry) {
          previous = undefined
          failed(error)
        }
      })
      // A change at the path or above it; for a listing, also under it.
      const changed = (event: RevisionEvents | null) => {
        if (
          retry ||
          event?.events.some((event) =>
            [event.path, ...(event.kind === 'move' ? [event.to] : [])].some((
              at,
            ) =>
              at === path || path.startsWith(`${at}/`) ||
              (listing && at.startsWith(`${path === '/' ? '' : path}/`))
            )
          )
        ) void refresh.run()
      }
      void kept(this.cache?.get<Value>(kind, key)).then(paint, () => {}).then(
        () => {
          if (closed) return
          this.fileListeners.add(changed)
          void refresh.run()
        },
      )
      return () => {
        closed = true
        refresh.close()
        this.fileListeners.delete(changed)
      }
    }
  }

  async sync(
    path: string,
    baseToken: string,
    content: string,
  ): Promise<SyncOutput> {
    const output = await this.tool<SyncOutput>('sync', {
      path,
      baseToken,
      content,
    })
    await this.cache?.put('document', path, {
      token: output.token,
      content: output.content,
    })
    return output
  }

  async write(path: string, content: string): Promise<WriteOutput> {
    const output = await this.tool<WriteOutput>('write', { path, content })
    await this.cache?.put('document', path, { token: output.token, content })
    return output
  }

  observeURL(glob: string, from: number | null, batch = false): string {
    const params = new URLSearchParams({ glob })
    if (from !== null) params.set('from', String(from))
    if (batch) params.set('batch', '1')
    return `/v1/observe?${params}`
  }

  private tool<Output>(name: string, input: unknown): Promise<Output> {
    return post(`/v1/tools/${name}`, input, inGroup(this.group))
  }
}
