import { renderToStaticMarkup } from 'react-dom/server'
import { assertEquals } from 'jsr:@std/assert@1'
import { HistoryEdge } from '~/components/history-edge'
import type { HistoryEdge as Edge } from '~/sdk/paged-observe'

const states: Record<string, Partial<Edge>> = {
  loading: { status: 'loading' },
  preparing: { status: 'preparing' },
  ready: { status: 'ready', hasEarlier: true },
  gap: { status: 'ready', hasEarlier: true, gap: true },
  retry: { status: 'error', error: 'Could not load older history' },
  exhausted: { status: 'ready' },
}
for (const [name, state] of Object.entries(states)) {
  Deno.test(`history edge ${name} accessible markup snapshot`, async () => {
    const edge: Edge = {
      status: 'ready',
      error: null,
      hasEarlier: false,
      gap: false,
      generation: 1,
      revision: 1,
      loadOlder() {},
      retry() {},
      ...state,
    }
    const actual = renderToStaticMarkup(<HistoryEdge edge={edge} />)
    const reference = await Deno.readTextFile(
      new URL(`./history-edge-snapshots/${name}.snap`, import.meta.url),
    )
    assertEquals(actual, reference.trimEnd())
  })
}
