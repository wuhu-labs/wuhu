import { assertEquals } from 'jsr:@std/assert@1'
import { reconcileScriptWatches } from './use-script.ts'
import { sidebarKey } from '../sidebar-catalog.ts'

Deno.test('sidebar script add/remove keeps unchanged watches alive and group-qualified', () => {
  const shared = { group: 'shared', path: '/.sidebars/work.sidebar.jsx' }
  const second = { ...shared, group: 'hazelui' }
  const third = { ...shared, path: '/.sidebars/new.sidebar.jsx' }
  const effects: string[] = []
  const watches = new Map<string, { stop(): void }>()
  const start = (address: typeof shared) => {
    const key = sidebarKey(address)
    effects.push(`start ${key}`)
    return {
      stop() {
        effects.push(`stop ${key}`)
      },
    }
  }
  reconcileScriptWatches(watches, [shared, second], start)
  const kept = watches.get(sidebarKey(shared))
  effects.length = 0
  reconcileScriptWatches(watches, [shared, third], start)
  assertEquals(effects, [
    `stop ${sidebarKey(second)}`,
    `start ${sidebarKey(third)}`,
  ])
  assertEquals(watches.get(sidebarKey(shared)), kept)
  effects.length = 0
  reconcileScriptWatches(watches, [third, shared], start)
  assertEquals(effects, [])
  reconcileScriptWatches(watches, [], start)
  assertEquals(watches.size, 0)
})
