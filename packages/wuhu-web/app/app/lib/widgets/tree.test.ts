import { assertEquals, assertThrows } from 'jsr:@std/assert@1'
import { sidebarTree, TreeError, widgetTree } from './tree.ts'

const el = (
  $element: string,
  props: Record<string, unknown> = {},
) => ({ $element, props })

Deno.test('a sidebar is PageCards and Widgets under one Sidebar', () => {
  const tree = sidebarTree(
    el('Sidebar', {
      name: 'Wuhu Dev',
      icon: 'code',
      home: '/wuhu/README.md',
      children: [
        el('PageCard', {
          page: '/_/sessions/a',
          children: [{ page: '/_/sessions/b', badge: 2 }],
        }),
        el('PageCard', { title: 'Channels', children: [] }),
        el('Widget', { src: '/.widgets/desk.widget.jsx', size: 'small' }),
        el('Widget', { src: '/.widgets/pool.widget.jsx' }),
      ],
    }),
  )
  assertEquals(tree, {
    name: 'Wuhu Dev',
    icon: 'code',
    home: '/wuhu/README.md',
    items: [
      {
        kind: 'page',
        card: {
          page: '/_/sessions/a',
          children: [{ page: '/_/sessions/b', badge: 2 }],
        },
      },
      { kind: 'page', card: { title: 'Channels', children: [] } },
      { kind: 'widget', src: '/.widgets/desk.widget.jsx', size: 'small' },
      { kind: 'widget', src: '/.widgets/pool.widget.jsx', size: 'wide' },
    ],
  })
})

Deno.test('a sidebar refuses anything but its two leaves', () => {
  for (
    const [value, message] of [
      [[el('Sidebar', { name: 'x' })], 'one <Sidebar>'],
      [el('Sidebar', {}), 'needs a name'],
      [
        el('Sidebar', { name: 'x', children: [el('Figure', { value: 1 })] }),
        'only PageCard and Widget',
      ],
      [
        el('Sidebar', {
          name: 'x',
          children: [el('Widget', { src: '/w.jsx', size: 'column' })],
        }),
        'wide or small',
      ],
      [
        el('Sidebar', { name: 'x', children: [el('PageCard', {})] }),
        'needs a page or a title',
      ],
    ] as const
  ) {
    assertThrows(() => sidebarTree(value), TreeError, message)
  }
})

Deno.test('a widget is one catalog card at a size it declares', () => {
  const card = el('Figure', { value: 3, label: 'Landed', to: '/wuhu' })
  assertEquals(widgetTree(card, ['small', 'wide'], 'small'), card)
  assertEquals(widgetTree(card, undefined, 'wide'), card)
  assertThrows(
    () => widgetTree(card, undefined, 'small'),
    TreeError,
    'draws wide, not small',
  )
  assertThrows(
    () => widgetTree(card, ['column'], 'wide'),
    TreeError,
    'sizes lists',
  )
})

Deno.test('a widget refuses what the demo bad.sidebar.jsx shows', () => {
  for (
    const [value, message] of [
      [[el('Figure'), el('Figure')], 'exactly one card'],
      [el('Slider', { value: 1 }), 'not a catalog card'],
      [el('Figure', { onClick: { $function: 'onClick' } }), 'is a function'],
      [
        el('Entity', { title: 'x', children: [el('Figure')] }),
        'not a part a template can hold',
      ],
      [el('List', {}), 'needs rows'],
      [null, 'one catalog card'],
    ] as const
  ) {
    assertThrows(() => widgetTree(value, undefined, 'wide'), TreeError, message)
  }
})

Deno.test('an icon is an IconaMoon name, and a Button is a link', () => {
  const ok = el('List', {
    icon: 'eye',
    rows: [{
      icon: 'lightning-1',
      label: 'a',
      lead: el('LeadIcon', { name: 'component' }),
    }],
    action: el('Button', { label: 'Open', to: '/a.md' }),
  })
  assertEquals(widgetTree(ok, undefined, 'wide'), ok)
  assertThrows(
    () => widgetTree(el('Figure', { icon: 'sparkles' }), undefined, 'wide'),
    TreeError,
    '"sparkles" is not an IconaMoon icon',
  )
  assertThrows(
    () =>
      widgetTree(
        el('List', { rows: [{ label: 'a', icon: 'nope' }] }),
        undefined,
        'wide',
      ),
    TreeError,
    '"nope" is not an IconaMoon icon',
  )
  assertThrows(
    () =>
      widgetTree(
        el('Subject', {
          name: 'x',
          actions: [el('LeadIcon', { name: 'nope' })],
        }),
        undefined,
        'wide',
      ),
    TreeError,
    'is not an IconaMoon icon',
  )
  assertThrows(
    () =>
      widgetTree(
        el('Doc', { title: 'x', action: el('Button', { label: 'Go' }) }),
        undefined,
        'wide',
      ),
    TreeError,
    'a <Button> is a link and needs to',
  )
})
