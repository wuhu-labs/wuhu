import type { CacheScope, OpenCache } from '~/lib/shell-sdk/open-cache.js'
import { forgetViewer } from './open-cache.ts'

function equal(actual: unknown, expected: unknown) {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

// Shared's kept groups list names every group the viewer kept.
function fakeCache(groups: { id: string }[] | undefined) {
  const purged: CacheScope[] = []
  const cache: OpenCache = {
    get: <Value>(scope: CacheScope, kind: string, key: string) =>
      Promise.resolve(
        (scope.group === 'shared' && kind === 'meta' && key === 'groups'
          ? groups
          : undefined) as Value | undefined,
      ),
    put: () => Promise.resolve(),
    purge: (scope) => {
      purged.push(scope)
      return Promise.resolve()
    },
  }
  return { cache, purged }
}

const device = { principal: 'lamp-oak-fern', spaceId: 'spc_test' }

Deno.test('forgetting a viewer purges every kept group', async () => {
  const { cache, purged } = fakeCache([
    { id: 'shared' },
    { id: 'lamp-oak-fern' },
    { id: 'moss-kite-drum' },
  ])
  await forgetViewer(device, cache)
  equal(
    purged.map((scope) => scope.group).sort(),
    ['lamp-oak-fern', 'moss-kite-drum', 'shared'],
  )
  equal(
    purged.every((scope) =>
      scope.space === 'spc_test' && scope.viewer === 'lamp-oak-fern'
    ),
    true,
  )
})

Deno.test('with no kept groups list, Shared alone is purged', async () => {
  const { cache, purged } = fakeCache(undefined)
  await forgetViewer(device, cache)
  equal(purged.map((scope) => scope.group), ['shared'])
})

Deno.test('a device without a persona has nothing to forget', async () => {
  const { cache, purged } = fakeCache([{ id: 'shared' }])
  await forgetViewer({ spaceId: 'spc_test' }, cache)
  equal(purged, [])
})
