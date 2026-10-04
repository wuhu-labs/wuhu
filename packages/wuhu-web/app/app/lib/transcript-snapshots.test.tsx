import { MemoryRouter, Outlet, Route, Routes } from 'react-router'
import { renderToStaticMarkup } from 'react-dom/server'
import { assertEquals } from 'jsr:@std/assert@1'
import { TurnTimeline } from '~/components/turn-timeline'
import { TurnInspector } from '~/components/turn-inspector'
import {
  fixtureProjection,
  fixtureState,
  semanticFixtures,
} from './transcript-fixtures.test.ts'
import { closedInspection, inspected } from './turn-inspection.ts'

const fixture = (name: string) =>
  semanticFixtures.find((fixture) => fixture.name === name)!
const idle = () => {}
const names = { session: () => undefined, principal: (id: string) => id }
const settled = fixture('all-results-still-exposed')
const folded = fixture('next-committed-folds')
const context = fixture('notice-does-not-fold')
const projection = fixtureProjection(folded)
const history = inspected(closedInspection, {
  kind: 'history',
  summary: 'summary:7:1:0',
})
const detail = inspected(history, { kind: 'tool', callID: 'read' })
const inspector = (inspection: typeof history) => (
  <TurnInspector
    inspection={inspection}
    state={fixtureState(folded)}
    projection={projection}
    inspect={idle}
    returnToHistory={idle}
    close={idle}
  />
)
const timeline = (source: typeof folded) => (
  <TurnTimeline
    projection={fixtureProjection(source)}
    status={null}
    group='shared'
    names={names}
    inspect={idle}
  />
)
const snapshots = {
  latest: timeline(settled),
  folded: timeline(folded),
  context: timeline(context),
  fallback: timeline(fixture('malformed-notice-no-parent')),
  history: inspector(history),
  detail: inspector(detail),
  sends: timeline(fixture('consecutive-sends-and-trailing-work')),
  receipt: timeline(fixture('receipt-tail-prepend-folded-declaration')),
  bookmark: timeline(fixture('bookmark-after-assistant-remains-visible')),
  placeholder: timeline(
    fixture('empty-stream-placeholder-working-without-fold'),
  ),
}
for (const [name, view] of Object.entries(snapshots)) {
  Deno.test(`transcript ${name} accessible HTML golden`, async () => {
    const markup = renderToStaticMarkup(
      <MemoryRouter>
        <Routes>
          <Route element={<Outlet context={{ group: 'shared' }} />}>
            <Route index element={view} />
          </Route>
        </Routes>
      </MemoryRouter>,
    )
    const actual = markup.replace(
      /(<time dateTime="[^"]+">|<time datetime="[^"]+">)[^<]+<\/time>/g,
      '$1[localized time]</time>',
    )
    const path = new URL(`./transcript-snapshots/${name}.snap`, import.meta.url)
    if (Deno.args.includes('--update-snapshots')) {
      await Deno.writeTextFile(path, actual + '\n')
    }
    assertEquals(actual, (await Deno.readTextFile(path)).trimEnd())
  })
}
