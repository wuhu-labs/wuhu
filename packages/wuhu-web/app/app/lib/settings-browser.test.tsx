import { renderToStaticMarkup } from 'react-dom/server'
import { assert, assertEquals } from 'jsr:@std/assert@1'
import { BrowserCard } from '~/components/settings-browser'

Deno.test('browser settings card accessible markup snapshot', async () => {
  const actual = renderToStaticMarkup(<BrowserCard enrolled />)
  const reference = await Deno.readTextFile(
    new URL('./settings-browser-snapshots/default.snap', import.meta.url),
  )
  assertEquals(actual, reference.trimEnd())
})

Deno.test('a browser without its own key offers no notifications', () => {
  const actual = renderToStaticMarkup(<BrowserCard enrolled={false} />)
  assert(!actual.includes('notifications'), actual)
  assert(actual.includes('send with'), actual)
})
