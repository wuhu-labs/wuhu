import { GlobalRegistrator } from '@happy-dom/global-registrator'
import { assertEquals } from 'jsr:@std/assert@1'
import { act } from 'react'
import { createRoot } from 'react-dom/client'
import type { ListOutput, ReadOutput } from './contract.gen.ts'
import type { SpaceClient } from '~/sdk/client'
import { useSidebarFiles } from './use-sidebar-files.ts'

Deno.test('sidebar listing and file refresh keep last rendered catalog until replacement files arrive', async () => {
  GlobalRegistrator.register()
  ;(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean })
    .IS_REACT_ACT_ENVIRONMENT = true
  let listing: (output: ListOutput) => void = () => {}
  const reads = new Map<string, (output: ReadOutput) => void>()
  const client = {
    list: () => (receive: typeof listing) => {
      listing = receive
      return () => {}
    },
    read: (path: string) => (receive: (output: ReadOutput) => void) => {
      reads.set(path, receive)
      return () => {
        reads.delete(path)
      }
    },
  } as unknown as SpaceClient
  const host = document.createElement('div')
  const root = createRoot(host)
  function Probe() {
    const files = useSidebarFiles(client)
    return (
      <div>
        {files === null ? 'Loading' : files.map(({ title }) => title).join(',')}
      </div>
    )
  }
  const entries = (names: string[]): ListOutput => ({
    entries: names.map((name) => ({
      name,
      kind: 'file',
      size: 0,
      token: name,
      mtime: 0,
    })),
  })
  const file = (path: string, title: string) =>
    reads.get(path)!({
      token: title,
      content: JSON.stringify({ title, sections: [] }),
    })
  try {
    await act(() => root.render(<Probe />))
    assertEquals(host.textContent, 'Loading')
    await act(() => listing(entries(['first.json'])))
    await act(() => file('/.sidebars/first.json', 'First'))
    assertEquals(host.textContent, 'First')
    await act(() => listing(entries(['first.json', 'second.json'])))
    assertEquals(host.textContent, 'First')
    await act(() => file('/.sidebars/first.json', 'Refreshed'))
    assertEquals(host.textContent, 'First')
    await act(() => file('/.sidebars/second.json', 'Second'))
    assertEquals(host.textContent, 'Refreshed,Second')
    await act(() => file('/.sidebars/first.json', 'Newest'))
    assertEquals(host.textContent, 'Newest,Second')
  } finally {
    await act(() => root.unmount())
    await GlobalRegistrator.unregister()
  }
})
