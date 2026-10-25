import { assertEquals } from 'jsr:@std/assert@1'
import { CatalogCard } from '@wuhu/ui'
import { renderToStaticMarkup } from 'react-dom/server'

for (const size of ['small', 'wide'] as const) {
  Deno.test(`overfilled ${size} Figure renders only its allowance`, () => {
    const html = renderToStaticMarkup(
      <CatalogCard
        size={size}
        links={{ href: () => null, navigate: () => {} }}
        element={{
          $element: 'Figure',
          props: {
            value: 5,
            unit: 'items',
            label: 'Landed',
            icon: 'check',
            note: 'Hidden note',
            chart: [1, 2, 3],
            meter: { value: 1, max: 2 },
          },
        }}
      />,
    )
    assertEquals(html.includes('Landed'), true)
    assertEquals(html.includes('Hidden note'), size === 'wide')
    assertEquals(html.includes('class="orb"'), size === 'wide')
    assertEquals(html.includes('k-chart'), size === 'wide')
    assertEquals(html.includes('k-ring'), false)
  })

  Deno.test(`overfilled ${size} List drops whole rows`, () => {
    const html = renderToStaticMarkup(
      <CatalogCard
        size={size}
        links={{ href: () => null, navigate: () => {} }}
        element={{
          $element: 'List',
          props: {
            title: 'In flight',
            rows: Array.from(
              { length: 8 },
              (_, i) => ({
                label: `Row ${i + 1} with a long title that must ellipsize`,
                caption: 'One line caption',
                trail: 'One line trail',
              }),
            ),
          },
        }}
      />,
    )
    const cap = size === 'small' ? 3 : 6
    assertEquals((html.match(/class="row /g) ?? []).length, cap)
    assertEquals(html.includes(`Row ${cap} with`), true)
    assertEquals(html.includes(`Row ${cap + 1} with`), false)
    assertEquals(html.includes('--catalog-row-lines:1'), true)
  })
}

Deno.test('Figure falls back to icon or meter when their preferred prop is absent', () => {
  for (const size of ['small', 'wide'] as const) {
    const html = renderToStaticMarkup(
      <CatalogCard
        size={size}
        links={{ href: () => null, navigate: () => {} }}
        element={{
          $element: 'Figure',
          props: { value: 5, icon: 'check', meter: { value: 1, max: 2 } },
        }}
      />,
    )
    assertEquals(html.includes('class="orb"'), true)
    assertEquals(html.includes('k-ring'), size === 'wide')
  }
})
