import { interceptedNavigation } from './shell-sdk/shell.js'

const page = 'https://space.test:5531/notes/index.html'

const leftClick = {
  defaultPrevented: false,
  button: 0,
  metaKey: false,
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
}

const plainAnchor = { href: '/guide.md', download: false, target: '' }

Deno.test('interceptedNavigation decides per anchor', () => {
  const cases: {
    name: string
    anchor: { href: string; download: boolean; target: string }
    expected: string | null
  }[] = [
    {
      name: 'same-origin relative',
      anchor: plainAnchor,
      expected: '/guide.md',
    },
    {
      name: 'same-origin absolute with search and hash',
      anchor: { ...plainAnchor, href: 'https://space.test:5531/a?q=1#part' },
      expected: '/a?q=1#part',
    },
    {
      name: 'mailto',
      anchor: { ...plainAnchor, href: 'mailto:someone@example.test' },
      expected: null,
    },
    {
      name: 'download attribute',
      anchor: { ...plainAnchor, download: true },
      expected: null,
    },
    {
      name: 'target=_blank',
      anchor: { ...plainAnchor, target: '_blank' },
      expected: null,
    },
    {
      name: 'target=_BLANK',
      anchor: { ...plainAnchor, target: '_BLANK' },
      expected: null,
    },
    {
      name: 'target=_top',
      anchor: { ...plainAnchor, target: '_top' },
      expected: null,
    },
    {
      name: 'named target',
      anchor: { ...plainAnchor, target: 'sidebar' },
      expected: null,
    },
    {
      name: 'target=_self',
      anchor: { ...plainAnchor, target: '_self' },
      expected: '/guide.md',
    },
    {
      name: 'same-document hash',
      anchor: { ...plainAnchor, href: '#section' },
      expected: null,
    },
    {
      name: 'same-path hash with search change',
      anchor: { ...plainAnchor, href: '/notes/index.html?q=2#part' },
      expected: '/notes/index.html?q=2#part',
    },
    {
      name: 'other-path hash',
      anchor: { ...plainAnchor, href: '/a#part' },
      expected: '/a#part',
    },
    {
      name: 'protocol-relative other host',
      anchor: { ...plainAnchor, href: '//other.test/x' },
      expected: null,
    },
    {
      name: 'protocol-relative same host',
      anchor: { ...plainAnchor, href: '//space.test:5531/x' },
      expected: '/x',
    },
    {
      name: 'cross-origin host',
      anchor: { ...plainAnchor, href: 'https://other.test/x' },
      expected: null,
    },
    {
      name: 'cross-origin port (API origin)',
      anchor: { ...plainAnchor, href: 'https://space.test:5530/v1/server' },
      expected: null,
    },
    {
      name: 'cross-scheme',
      anchor: { ...plainAnchor, href: 'http://space.test:5531/x' },
      expected: null,
    },
    {
      name: 'hostless wuhu link names this space',
      anchor: {
        ...plainAnchor,
        href: 'wuhu:/_/sessions/s1?view=transcript#end',
      },
      expected: '/_/sessions/s1?view=transcript#end',
    },
    {
      name: 'hostful wuhu link stays with the browser',
      anchor: { ...plainAnchor, href: 'wuhu://space.test:5530/_/sessions/s1' },
      expected: null,
    },
  ]
  for (const { name, anchor, expected } of cases) {
    const actual = interceptedNavigation(anchor, leftClick, page)
    if (actual !== expected) {
      throw new Error(`${name}: expected ${expected}, got ${actual}`)
    }
  }
})

Deno.test('interceptedNavigation defers to browser-handled clicks', () => {
  const cases: { name: string; click: typeof leftClick }[] = [
    {
      name: 'default prevented',
      click: { ...leftClick, defaultPrevented: true },
    },
    { name: 'middle button', click: { ...leftClick, button: 1 } },
    { name: 'meta', click: { ...leftClick, metaKey: true } },
    { name: 'ctrl', click: { ...leftClick, ctrlKey: true } },
    { name: 'shift', click: { ...leftClick, shiftKey: true } },
    { name: 'alt', click: { ...leftClick, altKey: true } },
  ]
  for (const { name, click } of cases) {
    if (interceptedNavigation(plainAnchor, click, page) !== null) {
      throw new Error(`${name}: expected null`)
    }
  }
})
