import { GlobalRegistrator } from '@happy-dom/global-registrator'
import { assertEquals } from 'jsr:@std/assert@1'
import { act } from 'react'
import { createRoot } from 'react-dom/client'

Deno.test('glass menu keyboard opens at the right edge, keeps disabled inert, selects and returns focus', async () => {
  GlobalRegistrator.register()
  ;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean })
    .IS_REACT_ACT_ENVIRONMENT = true
  const { GlassMenu } = await import('@wuhu/ui')
  const host = document.createElement('div')
  document.body.append(host)
  const root = createRoot(host)
  const selected: string[] = []
  const key = async (element: Element, value: string) => {
    await act(() => {
      element.dispatchEvent(
        new KeyboardEvent('keydown', { key: value, bubbles: true }),
      )
    })
  }
  try {
    await act(() =>
      root.render(
        <GlassMenu
          label='Targets'
          sections={[[
            {
              label: 'First',
              selected: true,
              onSelect: () => selected.push('First'),
            },
            {
              label: 'Disabled',
              disabled: true,
              onSelect: () => selected.push('Disabled'),
            },
            {
              label: 'Last',
              selected: false,
              onSelect: () => selected.push('Last'),
            },
          ]]}
        >
          Agent
        </GlassMenu>,
      )
    )
    const trigger = host.querySelector('button')!
    trigger.focus()
    await key(trigger, 'ArrowUp')
    assertEquals(trigger.getAttribute('aria-expanded'), 'true')
    assertEquals(document.activeElement?.textContent, 'Last')
    await key(document.activeElement!, 'Home')
    assertEquals(document.activeElement?.textContent, 'First✓')
    assertEquals(document.activeElement?.getAttribute('aria-checked'), 'true')
    await key(document.activeElement!, 'ArrowDown')
    assertEquals(document.activeElement?.textContent, 'Disabled')
    await key(document.activeElement!, 'Enter')
    assertEquals(selected, [])
    await key(document.activeElement!, 'ArrowDown')
    assertEquals(document.activeElement?.textContent, 'Last')
    await key(document.activeElement!, 'Escape')
    assertEquals(trigger.getAttribute('aria-expanded'), 'false')
    assertEquals(document.activeElement, trigger)
    const closedEscape = new KeyboardEvent('keydown', {
      key: 'Escape',
      bubbles: true,
      cancelable: true,
    })
    trigger.dispatchEvent(closedEscape)
    assertEquals(closedEscape.defaultPrevented, false)
    assertEquals(selected, [])
  } finally {
    await act(() => root.unmount())
    host.remove()
    await GlobalRegistrator.unregister()
  }
})
