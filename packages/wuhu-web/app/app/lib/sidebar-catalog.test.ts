import { assertEquals, assertRejects, assertThrows } from 'jsr:@std/assert@1'
import {
  catalogSidebars,
  changeSidebarVisibility,
  hiddenSidebars,
  namedSidebars,
  readSidebarPreferences,
  sidebarGroupRows,
  sidebarGroups,
  sidebarKey,
  sidebarScripts,
  sidebarSettingsPath,
  writeSidebarVisibility,
} from './sidebar-catalog.ts'
import type { GroupDetail, WriteInput } from './contract.gen.ts'
import { ApiError } from '~/sdk/errors'
import { everything, sidebarName } from './sidebars.ts'
import { sharedGroup } from './groups.ts'

const detail = (id: string, alias: string): GroupDetail => ({
  id,
  alias,
  personal: false,
  open: true,
  secrets: 'owner',
  entries: [],
})
const summaries = [
  { id: 'z-group', readable: true, member: false },
  { id: 'a-group', readable: true, member: true },
  { id: 'shared', readable: true, member: true, admin: true },
  { id: 'private', readable: false },
]
const groups = sidebarGroups(summaries, [
  detail('z-group', 'zoo'),
  detail('a-group', 'alpha'),
  detail('shared', 'shared'),
])
const address = { group: 'z-group', path: '/.sidebars/work.json' }

Deno.test('catalog includes readable nonmembers; unknown details retain id fallback and roles independently', () => {
  assertEquals(groups.map(({ id, label, role }) => ({ id, label, role })), [
    { id: 'shared', label: 'Shared', role: 'Admin' },
    { id: 'a-group', label: 'alpha', role: 'Member' },
    { id: 'z-group', label: 'zoo', role: 'Read-only' },
  ])
  const fallback = sidebarGroups(summaries, [detail('a-group', 'alpha')])
  assertEquals(fallback.map(({ id }) => id), ['shared', 'a-group', 'z-group'])
  assertEquals(fallback[2], {
    id: 'z-group',
    label: 'z-group',
    alias: 'z-group',
    metadata: 'loading',
    open: null,
    role: 'Read-only',
  })
  assertEquals(
    catalogSidebars(
      fallback,
      (id) =>
        id === 'z-group'
          ? null
          : [{ path: address.path, title: 'Work', sections: [] }],
      [],
    ).length,
    2,
  )
})

Deno.test('one catalog owns final runtime titles, shared display suffixes, hidden rows, group selection and per-group sidebars', () => {
  const entries = catalogSidebars(
    groups,
    () => [{ path: address.path, title: 'Work', sections: [] }],
    [address],
  )!
  const named = namedSidebars(entries, () => 'Iterations')
  assertEquals(named.map(({ title }) => title), [
    'Iterations · Shared',
    'Iterations · alpha',
    'Work',
  ])
  assertEquals(named.map(({ visible }) => visible), [true, true, false])
  assertEquals(
    new Set(
      named.map((entry) =>
        sidebarKey({ group: entry.group.id, path: entry.path })
      ),
    ).size,
    3,
  )
  const rows = sidebarGroupRows(groups, named, 'z-group')
  assertEquals(rows.map(({ selected }) => selected), [false, false, true])
  assertEquals(rows[2].sidebars, [named[2]])
  assertEquals(sidebarGroupRows(groups, named, 'gone')[0].selected, true)
  assertEquals(sidebarGroupRows([], [], null), [])
  assertEquals(
    namedSidebars(
      entries,
      (entry) => entry.group.id === 'z-group' ? 'Unique' : null,
    ).map(({ title }) => title),
    ['Work · Shared', 'Work · alpha', 'Work · zoo'],
  )
})

Deno.test('hidden scripts do not run', () => {
  const entries = catalogSidebars(
    groups,
    () => [{ path: address.path, title: 'Script', script: true }],
    [address],
  )!
  assertEquals(sidebarScripts(entries), [{
    group: 'shared',
    path: address.path,
  }, { group: 'a-group', path: address.path }])
  assertEquals(
    sidebarScripts(entries.map((entry) => ({ ...entry, visible: false }))),
    [],
  )
})

Deno.test('visibility defaults to shown; malformed preferences retain last good hidden addresses and surface Settings error', () => {
  const other = { group: 'gone', path: '/.sidebars/old.json' }
  const hidden = changeSidebarVisibility([other], address, false)
  assertEquals(hidden, [other, address])
  assertEquals(changeSidebarVisibility(hidden, address, false), hidden)
  assertEquals(changeSidebarVisibility(hidden, address, true), [other])
  assertEquals(hiddenSidebars(JSON.stringify({ hidden })), hidden)
  assertThrows(() => hiddenSidebars('{"hidden":[{}]}'))
  const initial = { hidden: [], error: null }
  assertEquals(readSidebarPreferences(initial, 'bad'), {
    hidden: [],
    error: "Sidebar settings can't be read",
  })
  const good = readSidebarPreferences(initial, JSON.stringify({ hidden }))
  assertEquals(readSidebarPreferences(good, 'null'), {
    hidden,
    error: "Sidebar settings can't be read",
  })
  assertEquals(readSidebarPreferences(good, null), initial)
})

Deno.test('first write is create-only and existing writes preserve unrelated document keys and addresses', async () => {
  const writes: WriteInput[] = []
  const write = (input: WriteInput) => {
    writes.push(input)
    return Promise.resolve()
  }
  await writeSidebarVisibility(
    { read: () => Promise.resolve(null), write },
    address,
    false,
  )
  assertEquals(writes[0], {
    path: sidebarSettingsPath,
    content: JSON.stringify({ hidden: [address] }),
    createOnly: true,
  })
  const other = { group: 'a-group', path: '/.sidebars/new.json' }
  await writeSidebarVisibility(
    {
      read: () =>
        Promise.resolve({
          token: 'fresh',
          content: JSON.stringify({
            version: 7,
            hidden: [other, address],
            extra: { theme: 'kept' },
          }),
        }),
      write,
    },
    address,
    true,
  )
  assertEquals(writes[1], {
    path: sidebarSettingsPath,
    content: JSON.stringify({
      version: 7,
      hidden: [other],
      extra: { theme: 'kept' },
    }),
    ifMatch: 'fresh',
  })
})

Deno.test('conflict rereads and reapplies only this address once, preserving a concurrent different address', async () => {
  const other = { group: 'a-group', path: '/.sidebars/new.json' }
  const writes: WriteInput[] = []
  let reads = 0
  const conflict = new ApiError(409, { code: 'conflict', message: 'stale' })
  const hidden = await writeSidebarVisibility(
    {
      read: () =>
        Promise.resolve(
          ++reads === 1
            ? { token: 'old', content: '{"hidden":[]}' }
            : { token: 'new', content: JSON.stringify({ hidden: [other] }) },
        ),
      write: (input) => {
        writes.push(input)
        return writes.length === 1
          ? Promise.reject(conflict)
          : Promise.resolve()
      },
    },
    address,
    false,
  )
  assertEquals(reads, 2)
  assertEquals(hidden, [other, address])
  assertEquals(writes[1].ifMatch, 'new')
  assertEquals(JSON.parse(writes[1].content), { hidden: [other, address] })
  reads = 0
  await assertRejects(() =>
    writeSidebarVisibility(
      {
        read: () => {
          reads++
          return Promise.resolve(null)
        },
        write: () => Promise.reject(conflict),
      },
      address,
      false,
    ), ApiError)
  assertEquals(reads, 2)
})

Deno.test('unreadable preferences never write; non-conflicts do not retry', async () => {
  let written = false
  await assertRejects(() =>
    writeSidebarVisibility(
      {
        read: () => Promise.resolve({ token: 'old', content: 'bad' }),
        write: () => {
          written = true
          return Promise.resolve()
        },
      },
      address,
      false,
    )
  )
  assertEquals(written, false)
  let reads = 0
  await assertRejects(
    () =>
      writeSidebarVisibility(
        {
          read: () => {
            reads++
            return Promise.resolve(null)
          },
          write: () => Promise.reject(new Error('offline')),
        },
        address,
        false,
      ),
    Error,
    'offline',
  )
  assertEquals(reads, 1)
})

Deno.test('metadata distinguishes pending from failed without discarding successful group details', () => {
  const pending = sidebarGroups(summaries, [])
  const failed = sidebarGroups(
    summaries,
    [detail('a-group', 'alpha')],
    new Set(['z-group']),
  )
  assertEquals(pending.find(({ id }) => id === 'z-group')?.metadata, 'loading')
  assertEquals(failed.find(({ id }) => id === 'z-group')?.metadata, 'failed')
  assertEquals(failed.find(({ id }) => id === 'a-group')?.label, 'alpha')
})

Deno.test('only Shared Everything keeps its localized title instead of the runtime name', () => {
  assertEquals(sidebarName(everything, sharedGroup), 'Everything')
  assertEquals(sidebarName(everything, 'a-group'), 'everything')
  const entries = catalogSidebars(
    groups,
    () => [{
      path: '/.sidebars/everything.sidebar.jsx',
      title: 'Localized Everything',
      script: true,
    }],
    [],
  )
  assertEquals(
    namedSidebars(entries, () => 'Runtime rename').map(({ title }) => title),
    [
      'Localized Everything',
      'Runtime rename · alpha',
      'Runtime rename · zoo',
    ],
  )
})
