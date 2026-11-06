import { renderToStaticMarkup } from 'react-dom/server'
import { MemoryRouter, Outlet, Route, Routes } from 'react-router'
import { Markdown } from '../components/markdown-view.tsx'

function assertEquals(actual: unknown, expected: unknown): void {
  const a = JSON.stringify(actual)
  const e = JSON.stringify(expected)
  if (a !== e) throw new Error(`expected ${e}, got ${a}`)
}

function html(source: string): string {
  return renderToStaticMarkup(
    <MemoryRouter>
      <Routes>
        <Route
          element={<Outlet context={{ group: 'shared', contentHost: null }} />}
        >
          <Route path='/' element={<Markdown>{source}</Markdown>} />
        </Route>
      </Routes>
    </MemoryRouter>,
  )
}

function links(source: string): string[] {
  return [...html(source).matchAll(/<a [^>]*>(.*?)<\/a>/g)].map((match) =>
    match[1]
  )
}

Deno.test('a bare wuhu: link autolinks in this group and across groups', () => {
  assertEquals(links('Done — wuhu:/notes/plan.md'), ['wuhu:/notes/plan.md'])
  assertEquals(links('See wuhu://team.localspace/notes/plan.md today'), [
    'wuhu://team.localspace/notes/plan.md',
  ])
  assertEquals(links('WUHU:/a/b?x=1#top'), ['WUHU:/a/b?x=1#top'])
})

Deno.test('a wuhu: link stops at trailing punctuation and unbalanced brackets', () => {
  assertEquals(links('Open wuhu:/notes/plan.md.'), ['wuhu:/notes/plan.md'])
  assertEquals(links('Is it wuhu:/a/b?'), ['wuhu:/a/b'])
  assertEquals(links('(see wuhu:/a/b), then'), ['wuhu:/a/b'])
  assertEquals(links('wuhu:/a/(draft).md;'), ['wuhu:/a/(draft).md'])
  assertEquals(links('"wuhu:/a/b"'), ['wuhu:/a/b'])
})

Deno.test('only a well-formed wuhu: link autolinks', () => {
  assertEquals(links('wuhu:notes'), [])
  assertEquals(links('wuhu://system/AGENTS.md'), [])
  assertEquals(links('wuhu:/a//b and wuhu:/a/../b'), [])
  assertEquals(links('just wuhu: alone'), [])
})

Deno.test('a wuhu: link in code stays plain text', () => {
  assertEquals(links('Run `wuhu:/notes/plan.md` there'), [])
  assertEquals(links('```\nwuhu:/notes/plan.md\n```'), [])
  assertEquals(links('    wuhu:/notes/plan.md'), [])
})

Deno.test('a wuhu: link already written as a link is not wrapped again', () => {
  assertEquals(links('[plan](wuhu:/notes/plan.md)'), ['plan'])
  assertEquals(links('[wuhu:/notes/plan.md](wuhu:/notes/plan.md)'), [
    'wuhu:/notes/plan.md',
  ])
  assertEquals(links('[see **wuhu:/x**](wuhu:/x)'), [
    'see <strong>wuhu:/x</strong>',
  ])
  assertEquals(links('<wuhu:/notes/plan.md>'), ['wuhu:/notes/plan.md'])
  assertEquals(links('ping @alice at wuhu:/a'), ['wuhu:/a'])
})

Deno.test('a mention keeps its handle and a wuhu: after it stays plain', () => {
  assertEquals(links('Ask @wuhu:/notes/plan.md'), [])
  assertEquals(
    html('Ask @wuhu:/notes/plan.md').includes(
      '<span class="wuhu-mention">@wuhu</span>',
    ),
    true,
  )
})
