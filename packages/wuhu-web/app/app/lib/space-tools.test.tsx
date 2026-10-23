import { renderToStaticMarkup } from 'react-dom/server'
import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1'
import { SpaceTools } from '~/components/space-tools'

Deno.test('Settings keeps its active button and hides New agent; other pages offer both', () => {
  const draw = (settings: boolean) =>
    renderToStaticMarkup(
      <SpaceTools
        settings={settings}
        onSettings={() => {}}
        onCreate={() => {}}
      />,
    )
  assertStringIncludes(draw(false), 'aria-label="New agent"')
  assertStringIncludes(draw(false), 'aria-pressed="false"')
  assertEquals(draw(true).includes('aria-label="New agent"'), false)
  assertStringIncludes(draw(true), 'aria-label="Settings"')
  assertStringIncludes(draw(true), 'aria-pressed="true"')
})
