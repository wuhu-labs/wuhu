/// <reference lib="deno.ns" />
import { GlobalRegistrator } from '@happy-dom/global-registrator'

// A media query list whose `matches` the test moves, calling its `change`
// listeners the way a browser does when the viewport crosses the threshold.
class FakeMediaQueryList {
  matches = false
  readonly listeners = new Set<() => void>()
  constructor(readonly media: string) {}
  addEventListener(_type: 'change', listener: () => void) {
    this.listeners.add(listener)
  }
  removeEventListener(_type: 'change', listener: () => void) {
    this.listeners.delete(listener)
  }
  addListener(listener: () => void) {
    this.listeners.add(listener)
  }
  removeListener(listener: () => void) {
    this.listeners.delete(listener)
  }
  change(matches: boolean) {
    this.matches = matches
    for (const listener of this.listeners) listener()
  }
}

interface Commit {
  compact: boolean
  mode: string
}

Deno.test({
  name: 'crossing the compact threshold renders compact and mode in one commit',
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    // Deno's test runner reports through the global event target, so the
    // window keeps Deno's own.
    const { addEventListener, removeEventListener, dispatchEvent } = globalThis
    GlobalRegistrator.register()
    Object.assign(globalThis, {
      addEventListener,
      removeEventListener,
      dispatchEvent,
    })
    const lists = new Map<string, FakeMediaQueryList>()
    const list = (query: string) => {
      let found = lists.get(query)
      if (found === undefined) {
        found = new FakeMediaQueryList(query)
        lists.set(query, found)
      }
      return found
    }
    globalThis.matchMedia = ((query: string) =>
      list(query)) as unknown as typeof globalThis.matchMedia
    ;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean })
      .IS_REACT_ACT_ENVIRONMENT = true
    try {
      const { act, useLayoutEffect } = await import('react')
      const { createRoot } = await import('react-dom/client')
      const { AppShell, useChrome } = await import('./app-shell.tsx')
      // The test reads commits, not motion; a cancelled native animation
      // would reject outside the test.
      const { MotionGlobalConfig } = await import('motion/react')
      MotionGlobalConfig.skipAnimations = true

      // Reads the shell's root after every commit, before paint. Reading the
      // chrome context re-renders it with every shell render.
      const commits: Commit[] = []
      const Probe = () => {
        useChrome()
        useLayoutEffect(() => {
          const root = document.querySelector('.wui-root')!
          commits.push({
            compact: root.getAttribute('data-wui-compact') === 'true',
            mode: root.classList.contains('wui-mode-focus') ? 'focus' : 'full',
          })
        })
        return null
      }

      const compactQuery = '(max-width: 63.999rem)'
      const cross = async (compact: boolean) => {
        await act(() => {
          list(compactQuery).change(compact)
        })
      }

      const host = document.createElement('div')
      document.body.append(host)
      const root = createRoot(host)
      await act(() =>
        root.render(
          <AppShell sidebar={null} topbar={null}>
            <Probe />
          </AppShell>,
        )
      )
      await cross(true)
      await cross(false)
      await act(() =>
        root.unmount()
      )

      const torn = commits.filter((commit) =>
        commit.compact !== (commit.mode === 'focus')
      )
      if (torn.length > 0) {
        throw new Error(
          `commits rendered compact without its mode: ${
            JSON.stringify(commits)
          }`,
        )
      }
      const settled = commits.map((commit) => commit.compact)
      if (!settled.includes(true) || settled.at(-1) !== false) {
        throw new Error(`the shell never crossed: ${JSON.stringify(commits)}`)
      }
    } finally {
      await GlobalRegistrator.unregister()
    }
  },
})
