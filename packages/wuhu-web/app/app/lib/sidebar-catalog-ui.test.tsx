import { renderToStaticMarkup } from 'react-dom/server'
import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1'
import { SidebarRail } from '~/components/space-sidebar'
import { GroupSettings } from '~/components/settings-groups'
import {
  groupSettingsHref,
  settingsHref,
  settingsPlace,
  settingsTopics,
} from '~/components/settings-nav'
import {
  catalogSidebars,
  namedSidebars,
  selectedSidebar,
  type SidebarGroup,
  sidebarGroupRows,
  sidebarKey,
} from './sidebar-catalog.ts'
import type { SidebarCatalog } from './use-sidebar-catalog.ts'
import type { ScriptState } from './widgets/use-script.ts'

const groups: SidebarGroup[] = [
  { id: 'shared', alias: 'shared', label: 'Shared', open: true, role: 'Admin' },
  {
    id: 'second',
    alias: 'hazelui',
    label: 'hazelui',
    open: false,
    role: 'Read-only',
  },
]
const path = '/.sidebars/iterations.sidebar.jsx'
const entries = catalogSidebars(
  groups,
  () => [{ path, title: 'iterations', script: true }],
  [],
)!
const scripts = new Map<string, ScriptState>(
  groups.map(({ id }) => [sidebarKey({ group: id, path }), {
    kind: 'ran',
    result: {
      ok: true,
      value: {
        $element: 'Sidebar',
        props: { name: 'Iterations', children: [] },
      },
      sizes: {},
    },
  }]),
)

Deno.test('rail uses runtime script name collision suffixes with group-qualified selection', () => {
  const markup = renderToStaticMarkup(
    <SidebarRail
      files={namedSidebars(entries, () => 'Iterations')}
      scripts={scripts}
      current={sidebarKey({ group: 'second', path })}
      onPick={() => {}}
    />,
  )
  assertStringIncludes(markup, 'aria-label="Iterations · Shared"')
  assertStringIncludes(markup, 'aria-label="Iterations · hazelui"')
  assertEquals((markup.match(/aria-pressed="true"/g) ?? []).length, 1)
})

Deno.test('rail and Groups settings consume the same catalog, including hidden rows and read-only group metadata', () => {
  const hiddenEntries = entries.map((entry) => ({
    ...entry,
    visible: entry.group.id === 'shared',
  }))
  const groupRows = sidebarGroupRows(
    groups,
    namedSidebars(hiddenEntries, () => 'Iterations'),
    'second',
  )
  const catalog: SidebarCatalog = {
    groups: groupRows,
    selectedGroup: groupRows[1],
    entries: namedSidebars(hiddenEntries, () => 'Iterations'),
    scripts,
    error: null,
    busy: false,
    setVisible: () => Promise.resolve(),
  }
  const rail = renderToStaticMarkup(
    <SidebarRail
      files={catalog.entries!.filter((entry) => entry.visible)}
      scripts={scripts}
      current={sidebarKey({ group: 'shared', path })}
      onPick={() => {}}
    />,
  )
  assertEquals(rail.includes('hazelui'), false)
  const settings = renderToStaticMarkup(
    <GroupSettings catalog={catalog} />,
  )
  assertStringIncludes(settings, 'hazelui')
  assertStringIncludes(settings, 'Private')
  assertStringIncludes(settings, 'Read-only')
  assertStringIncludes(settings, 'Show in sidebar')
  assertStringIncludes(settings, 'iterations')
  assertEquals(settings.includes('checked=""'), false)
  assertEquals(
    selectedSidebar(hiddenEntries, { group: 'second', sidebar: path })?.group
      .id,
    'shared',
  )
  assertEquals(
    selectedSidebar(entries, { group: 'second', sidebar: path })?.group.id,
    'second',
  )
  assertEquals(selectedSidebar([], { group: 'second', sidebar: path }), null)
  assertEquals(settingsTopics.groups.label, 'Groups')
  assertEquals(settingsPlace('?topic=groups').topic, 'groups')
})

Deno.test('settings links retain typed row addresses and encode group query values', () => {
  assertEquals(
    new URLSearchParams(groupSettingsHref('group+id &other').split('?')[1]).get(
      'group',
    ),
    'group+id &other',
  )
  assertEquals(
    new URLSearchParams(settingsHref('you', 'devices').split('?')[1]).get(
      'row',
    ),
    'devices',
  )
})
