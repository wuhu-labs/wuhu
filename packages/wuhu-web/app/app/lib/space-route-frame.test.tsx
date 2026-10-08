import { renderToStaticMarkup } from 'react-dom/server'
import { MemoryRouter } from 'react-router'
import { SpaceRouteFrame } from './space-route-frame.tsx'
import Enroll from '../routes/enroll.tsx'
import { screens } from './links.ts'

function assertIncludes(markup: string, needle: string, expected = true) {
  if (markup.includes(needle) !== expected) {
    throw new Error(`expected ${needle} presence ${expected}: ${markup}`)
  }
}

function inHost(embedded: boolean, topFrame: boolean, test: () => void) {
  const previous = ['webkit', 'top', 'location'].map((name) =>
    [
      name,
      Object.getOwnPropertyDescriptor(globalThis, name),
    ] as const
  )
  Object.defineProperties(globalThis, {
    top: { configurable: true, value: topFrame ? globalThis : {} },
    webkit: {
      configurable: true,
      value: embedded
        ? {
          messageHandlers: {
            wuhuEmbedded: {
              postMessage() {
                throw new Error(
                  'presence-only signal must not receive messages',
                )
              },
            },
          },
        }
        : undefined,
    },
    location: {
      configurable: true,
      value: { hash: '#token=jt_proof&space=spc_' + 'c'.repeat(32) },
    },
  })
  try {
    test()
  } finally {
    for (const [name, descriptor] of previous) {
      if (descriptor) Object.defineProperty(globalThis, name, descriptor)
      else Reflect.deleteProperty(globalThis, name)
    }
  }
}

Deno.test('the embedded space frame keeps every route body but never mounts SPA chrome', () => {
  const render = (pathname: string) =>
    renderToStaticMarkup(
      <MemoryRouter initialEntries={[pathname]}>
        <SpaceRouteFrame
          sidebar={<aside>agent-list</aside>}
          topbar={<header>page-header</header>}
          composer={<footer>composer</footer>}
        >
          <section>route-body:{pathname}</section>
        </SpaceRouteFrame>
      </MemoryRouter>,
    )
  const chrome = [
    'agent-list',
    'page-header',
    'composer',
    'wui-sidebar',
    'wui-surface',
  ]
  inHost(true, true, () => {
    for (
      const pathname of [
        screens.settings,
        '/',
        screens.templates,
        screens.sessions,
      ]
    ) {
      const embedded = render(pathname)
      assertIncludes(embedded, `route-body:${pathname}`)
      assertIncludes(embedded, 'wuhu-embedded-body')
      for (const part of chrome) assertIncludes(embedded, part, false)
    }
  })
  for (const [embedded, topFrame] of [[false, true], [true, false]]) {
    inHost(embedded, topFrame, () => {
      const browser = render(screens.settings)
      assertIncludes(browser, 'route-body:')
      for (const part of chrome) assertIncludes(browser, part)
      assertIncludes(browser, 'wuhu-embedded-body', false)
    })
  }
})

Deno.test('Enroll renders its content without SPA chrome in native and browser hosts', () => {
  for (const embedded of [false, true]) {
    inHost(embedded, true, () => {
      const markup = renderToStaticMarkup(
        <MemoryRouter initialEntries={[screens.enroll]}>
          <Enroll />
        </MemoryRouter>,
      )
      assertIncludes(markup, 'Enroll this browser?')
      assertIncludes(markup, '>Enroll</button>')
      assertIncludes(markup, 'wuhu-embedded-body', embedded)
      assertIncludes(markup, 'wuhu-standalone', !embedded)
      for (
        const part of [
          'wui-sidebar',
          'wui-topbar',
          'wui-composer',
          'wui-surface',
        ]
      ) {
        assertIncludes(markup, part, false)
      }
    })
  }
})
