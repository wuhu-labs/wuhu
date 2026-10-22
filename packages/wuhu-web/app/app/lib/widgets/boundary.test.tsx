import { GlobalRegistrator } from '@happy-dom/global-registrator'
import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1'
import { CatalogCard, type CatalogLinks } from '@wuhu/ui'
import { act } from 'react'
import { createRoot } from 'react-dom/client'
import { WidgetBoundary } from '~/components/widget-boundary'

const links: CatalogLinks = { href: () => null, navigate: () => {} }

// Shapes the tree check lets through but a mark cannot draw.
const broken = [
  { $element: 'Pattern', props: { days: [1], bands: 'x' } },
  { $element: 'Calendar', props: { days: [1, 2], offset: -1 } },
  { $element: 'Pattern', props: { days: [1], bands: [{ label: { a: 1 } }] } },
]

Deno.test('a card that throws while drawing becomes its error card, alone', async () => {
  GlobalRegistrator.register()
  ;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean })
    .IS_REACT_ACT_ENVIRONMENT = true
  const quiet = console.error
  console.error = () => {}
  try {
    const host = document.createElement('div')
    document.body.append(host)
    const root = createRoot(host)
    await act(() =>
      root.render(
        <>
          {broken.map((element, at) => (
            <WidgetBoundary key={at} src={`/.widgets/${at}.widget.jsx`}>
              <CatalogCard element={element} size='wide' links={links} />
            </WidgetBoundary>
          ))}
          <p>still here</p>
        </>,
      )
    )
    assertStringIncludes(host.textContent ?? '', 'still here')
    for (const at of broken.keys()) {
      assertStringIncludes(
        host.textContent ?? '',
        `/.widgets/${at}.widget.jsx: `,
      )
    }
    assertEquals(host.querySelectorAll('.s-err').length, broken.length)
    await act(() => root.unmount())
  } finally {
    console.error = quiet
    await GlobalRegistrator.unregister()
  }
})
