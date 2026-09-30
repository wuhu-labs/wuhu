import { renderToStaticMarkup } from 'react-dom/server'
import { ComposerZone } from '@wuhu/ui'

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(`expected ${String(expected)}, got ${String(actual)}`)
  }
}

const tokens = await Deno.readTextFile(
  new URL(import.meta.resolve('@wuhu/ui/tokens.css')),
)

function pointerEvents(selector: string): string | undefined {
  const escaped = selector.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  const rules = tokens.matchAll(
    new RegExp(`^\\s*${escaped}\\s*\\{([^}]*)\\}`, 'gm'),
  )
  return [...rules]
    .map((rule) => /pointer-events:\s*([\w-]+)/.exec(rule[1])?.[1])
    .findLast((value) => value !== undefined)
}

Deno.test('the zone passes clicks through and everything stacked in it, the reply strip included, catches them', () => {
  const markup = renderToStaticMarkup(
    <ComposerZone above={<button type='button'>×</button>}>
      <textarea />
    </ComposerZone>,
  )
  assertEquals(
    /<div class="wui-composer-zone"><div class="wui-composer-stack"><button type="button">×<\/button>/
      .test(markup),
    true,
  )
  assertEquals(pointerEvents('.wui-composer-zone'), 'none')
  assertEquals(pointerEvents('.wui-composer-stack'), undefined)
  assertEquals(pointerEvents('.wui-composer-stack > *'), 'auto')
  assertEquals(pointerEvents('.wui-composer'), undefined)
})

Deno.test('a hidden composer passes clicks through, except in compact focus where it stays', () => {
  assertEquals(pointerEvents('.wui-mode-focus .wui-composer-stack > *'), 'none')
  assertEquals(
    pointerEvents('.wui-root.wui-mode-focus .wui-composer-stack > *'),
    'auto',
  )
})
