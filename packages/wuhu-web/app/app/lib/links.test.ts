import {
  entryHref,
  fileHref,
  isSystemAddress,
  placeGroup,
  sessionHref,
  spaceLink,
  systemAddress,
  withGroup,
  withoutGroup,
} from './links.ts'

function assertEquals(actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

const origin = 'https://space.example:5530'

Deno.test('a share link to this host stays in the SPA', () => {
  assertEquals(
    spaceLink(
      'https://Space.example:5530/_/sessions/s1?view=transcript',
      'shared',
      undefined,
      { origin },
    ),
    '/_/sessions/s1?view=transcript',
  )
  assertEquals(
    spaceLink(
      'https://space.example:5530/notes/My%20Plan.md#top',
      'shared',
      undefined,
      { origin },
    ),
    '/notes/My%20Plan.md#top',
  )
})

Deno.test('a hostless wuhu link means this space', () => {
  assertEquals(
    spaceLink(
      'wuhu:/_/sessions/s1?view=transcript',
      'shared',
      '/notes/a.md',
      { origin },
    ),
    '/_/sessions/s1?view=transcript',
  )
  assertEquals(
    spaceLink(
      'WUHU:/notes/My%20Plan.md#top',
      'shared',
      undefined,
      { origin },
    ),
    '/notes/My%20Plan.md#top',
  )
  assertEquals(
    spaceLink(
      'wuhu:/a/../b',
      'shared',
      undefined,
      { origin },
    ),
    null,
  )
})

Deno.test('links to other hosts and the wuhu twin leave the SPA', () => {
  assertEquals(
    spaceLink(
      'https://elsewhere.test/_/sessions/s1',
      'shared',
      undefined,
      { origin },
    ),
    null,
  )
  assertEquals(
    spaceLink(
      'wuhu://space.example:5530/_/sessions/s1',
      'shared',
      undefined,
      { origin },
    ),
    null,
  )
  assertEquals(
    spaceLink(
      'mailto:a@b.c',
      'shared',
      undefined,
      { origin },
    ),
    null,
  )
})

Deno.test('plain and relative paths resolve against the document', () => {
  assertEquals(
    spaceLink(
      '/_/conversations/c1',
      'shared',
      '/notes/a.md',
      { origin },
    ),
    '/_/conversations/c1',
  )
  assertEquals(
    spaceLink(
      '../b.md?q=1',
      'shared',
      '/notes/deep/a.md',
      { origin },
    ),
    '/notes/b.md?q=1',
  )
  assertEquals(
    spaceLink(
      '#part',
      'shared',
      '/notes/a.md',
      { origin },
    ),
    null,
  )
})

Deno.test('a place in another group carries it in the query', () => {
  assertEquals(
    fileHref('/notes/a.md', 'sail-clock-pepper'),
    '/notes/a.md?group=sail-clock-pepper',
  )
  assertEquals(
    sessionHref('s1', 'sail-clock-pepper', 'context'),
    '/_/sessions/s1?view=context&group=sail-clock-pepper',
  )
  assertEquals(
    withGroup('/notes/a.md?q=1#top', 'sail-clock-pepper'),
    '/notes/a.md?q=1&group=sail-clock-pepper#top',
  )
  assertEquals(placeGroup('?q=1&group=sail-clock-pepper'), 'sail-clock-pepper')
  assertEquals(placeGroup(''), 'shared')
  assertEquals(withoutGroup('?q=1&group=sail-clock-pepper'), '?q=1')
  assertEquals(withoutGroup('?group=sail-clock-pepper'), '')
})

Deno.test('a share link with ?group= opens that group in the SPA', () => {
  assertEquals(
    spaceLink(
      'https://space.example:5530/notes/a.md?q=1&group=sail-clock-pepper#top',
      'shared',
      undefined,
      { origin },
    ),
    '/notes/a.md?q=1&group=sail-clock-pepper#top',
  )
  assertEquals(
    spaceLink(
      'https://space.example:5530/_/sessions/s1?group=sail-clock-pepper',
      'design',
      undefined,
      { origin },
    ),
    '/_/sessions/s1?group=sail-clock-pepper',
  )
})

Deno.test('an old group-host link opens that group in the SPA', () => {
  assertEquals(
    spaceLink(
      'https://sail-clock-pepper.space.example:5530/notes/a.md',
      'shared',
      undefined,
      { origin },
    ),
    '/notes/a.md?group=sail-clock-pepper',
  )
  assertEquals(
    spaceLink(
      'wuhu://sail-clock-pepper.localspace/notes/a.md',
      'shared',
      undefined,
      { origin },
    ),
    '/notes/a.md?group=sail-clock-pepper',
  )
  assertEquals(
    spaceLink('/notes/b.md', 'sail-clock-pepper', '/notes/a.md', { origin }),
    '/notes/b.md?group=sail-clock-pepper',
  )
  assertEquals(
    spaceLink(
      'https://a.b.space.example:5530/x.md',
      'shared',
      undefined,
      { origin },
    ),
    null,
  )
})

Deno.test('a localspace entry opens in its own group', () => {
  assertEquals(
    entryHref('wuhu://sail-clock-pepper.localspace/AGENTS.md', 'shared'),
    '/AGENTS.md?group=sail-clock-pepper',
  )
})

Deno.test('fileHref encodes file-path segments without an /f prefix', () => {
  assertEquals(
    fileHref('/notes/Brief & plan.md', 'shared'),
    '/notes/Brief%20%26%20plan.md',
  )
  assertEquals(fileHref('/templates/daily', 'shared'), '/templates/daily')
  assertEquals(
    fileHref('/_/sessions/s1/AGENTS.md', 'shared'),
    '/_/sessions/s1/AGENTS.md',
  )
})

Deno.test('a system entry opens on the system screen, a space entry as a file', () => {
  const skill = 'wuhu://system/skills/space-html-pages/SKILL.md'
  assertEquals(isSystemAddress(skill), true)
  assertEquals(
    entryHref(skill, 'shared'),
    '/_/system/skills/space-html-pages/SKILL.md',
  )
  assertEquals(systemAddress(entryHref(skill, 'shared')), skill)
  assertEquals(
    entryHref('wuhu://system/AGENTS.md', 'shared'),
    '/_/system/AGENTS.md',
  )
  assertEquals(
    systemAddress('/_/system/skills/a%20b/SKILL.md'),
    'wuhu://system/skills/a b/SKILL.md',
  )
  assertEquals(isSystemAddress('/.agents/skills/ci-watch/SKILL.md'), false)
  assertEquals(
    entryHref('/.agents/skills/ci-watch/SKILL.md', 'shared'),
    '/.agents/skills/ci-watch/SKILL.md',
  )
  for (const pathname of ['/_/system', '/_/system/', '/_/systems/a.md']) {
    assertEquals(systemAddress(pathname), null)
  }
})

Deno.test('flat group hosts link into this tenant, not another tenant', () => {
  assertEquals(
    spaceLink(
      'https://alice--alex.wuhu.studio/note.md',
      'shared',
      undefined,
      {
        origin: 'https://alex.wuhu.studio',
        contentHost: '{group}--alex.wuhu.studio',
      },
    ),
    '/note.md?group=alice',
  )
  assertEquals(
    spaceLink(
      'https://shared--alex.wuhu.studio/note.md',
      'alice',
      undefined,
      {
        origin: 'https://alex.wuhu.studio',
        contentHost: '{group}--alex.wuhu.studio',
      },
    ),
    '/note.md',
  )
  assertEquals(
    spaceLink(
      'https://alice--bob.wuhu.studio/note.md',
      'shared',
      undefined,
      {
        origin: 'https://alex.wuhu.studio',
        contentHost: '{group}--alex.wuhu.studio',
      },
    ),
    null,
  )
  assertEquals(
    spaceLink(
      'https://nested.alice--alex.wuhu.studio/note.md',
      'shared',
      undefined,
      {
        origin: 'https://alex.wuhu.studio',
        contentHost: '{group}--alex.wuhu.studio',
      },
    ),
    null,
  )
})

Deno.test('flat-looking links on a self-hosted server remain external', () => {
  assertEquals(
    spaceLink(
      'https://alice--box.test/note.md',
      'shared',
      undefined,
      { origin: 'https://box.test' },
    ),
    null,
  )
  assertEquals(
    spaceLink(
      'https://alice.box.test/note.md',
      'shared',
      undefined,
      { origin: 'https://box.test' },
    ),
    '/note.md?group=alice',
  )
})

Deno.test('flat links follow the advertised template and canonical port', () => {
  assertEquals(
    spaceLink(
      'https://alice--alex.test/note.md',
      'shared',
      undefined,
      { origin: 'https://alex.test', contentHost: '{group}--alex.test:443' },
    ),
    '/note.md?group=alice',
  )
  assertEquals(
    spaceLink(
      'https://alice--alex.test:5530/note.md',
      'shared',
      undefined,
      {
        origin: 'https://alex.test:5530',
        contentHost: '{group}--alex.test:5530',
      },
    ),
    '/note.md?group=alice',
  )
  assertEquals(
    spaceLink(
      'https://alice--bob.test/note.md',
      'shared',
      undefined,
      { origin: 'https://alex.test', contentHost: '{group}--alex.test' },
    ),
    null,
  )
})
