import { renderToStaticMarkup } from 'react-dom/server'
import { assertEquals } from 'jsr:@std/assert@1'
import { BrowserCard } from '~/components/settings-browser'

Deno.test('browser settings card accessible markup snapshot', async () => {
  const actual = renderToStaticMarkup(<BrowserCard />)
  const reference = await Deno.readTextFile(
    new URL('./settings-browser-snapshots/default.snap', import.meta.url),
  )
  assertEquals(actual, reference.trimEnd())
})
