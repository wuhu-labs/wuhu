import {
  appCacheBudgets,
  byteLength,
  type CacheKind,
  type CacheScope,
  type OpenCache,
  openCache,
  sharedGroup,
} from '~/lib/shell-sdk/open-cache.js'
import type { EnrolledDevice } from './auth'

// What this browser last saw of one group as one viewer: the paint a reopen
// shows before the live feeds arrive.
export interface ViewerCache {
  get<Value>(kind: CacheKind, key: string): Promise<Value | undefined>
  put(kind: CacheKind, key: string, value: unknown): Promise<void>
}

export interface ViewerCaches {
  of(group: string): ViewerCache
}

type Viewer = Pick<EnrolledDevice, 'principal' | 'spaceId'>

let shared: OpenCache | undefined
const appCache = () => shared ??= openCache({ budgets: appCacheBudgets })

function viewerScope(device: Viewer | null, group: string): CacheScope | null {
  return device?.principal == null
    ? null
    : { space: device.spaceId, group, viewer: device.principal }
}

function scopedCache(scope: CacheScope, cache: OpenCache): ViewerCache {
  return {
    // A cache that fails is an empty one.
    get: <Value>(kind: CacheKind, key: string) =>
      cache.get<Value>(scope, kind, key).catch(() => undefined),
    put: (kind, key, value) => {
      const text = JSON.stringify(value)
      return cache.put(scope, kind, key, value, byteLength(text)).catch(
        () => undefined,
      )
    },
  }
}

export function viewerCaches(
  device: Viewer | null,
  cache: OpenCache = appCache(),
): ViewerCaches | null {
  if (device?.principal == null) return null
  const caches = new Map<string, ViewerCache>()
  return {
    of(group) {
      let found = caches.get(group)
      if (found === undefined) {
        found = scopedCache(viewerScope(device, group)!, cache)
        caches.set(group, found)
      }
      return found
    },
  }
}

// Shared's cache keeps the groups list, so it names every group kept.
export async function forgetViewer(
  device: Viewer | null,
  cache: OpenCache = appCache(),
): Promise<void> {
  const scope = viewerScope(device, sharedGroup)
  if (scope === null) return
  const groups = await scopedCache(scope, cache)
    .get<{ id: string }[]>('meta', 'groups') ?? []
  const kept = new Set([sharedGroup, ...groups.map((group) => group.id)])
  await Promise.all(
    [...kept].map((group) => cache.purge({ ...scope, group })),
  )
}
