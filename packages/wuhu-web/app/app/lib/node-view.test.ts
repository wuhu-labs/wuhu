import { ApiError } from '../sdk/errors.ts'
import type { EntryKind } from './contract.gen.ts'
import { loadNode, type NodeSource } from './node-view.ts'

function expectEqual(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

const origin = 'https://shared.space.test'

function space(
  files: Record<string, string>,
  stats: string[] = [],
): NodeSource {
  const kinds = new Map<string, EntryKind>([['/', 'directory']])
  for (const path of Object.keys(files)) kinds.set(path, 'file')
  return {
    stat: (path) => {
      stats.push(path)
      const kind = kinds.get(path)
      return kind === undefined
        ? Promise.reject(
          new ApiError(404, { code: 'notFound', message: `${path} missing` }),
        )
        : Promise.resolve({ kind })
    },
    read: (path) => Promise.resolve({ content: files[path], token: 't1' }),
  }
}

const home = (source: NodeSource) => loadNode(source, origin, '/', '', 0)

Deno.test('/ opens index.html in the frame, ahead of index.md', async () => {
  const stats: string[] = []
  const source = space({
    '/index.html': '<h1>Harbor</h1>',
    '/index.md': '# Harbor',
  }, stats)
  expectEqual(await home(source), {
    state: 'html',
    origin,
    src: `${origin}/index.html`,
  })
  expectEqual(stats, ['/index.html'])
})

Deno.test('/ opens index.md in the viewer when there is no index.html', async () => {
  const source = space({ '/index.md': '# Harbor', '/README.md': '# Readme' })
  expectEqual(await home(source), {
    state: 'markdown',
    content: '# Harbor',
    path: '/index.md',
    token: 't1',
  })
})

Deno.test('/ without either index shows the root listing', async () => {
  const stats: string[] = []
  const source = space({ '/README.md': '# Readme' }, stats)
  expectEqual(await home(source), { state: 'html', origin, src: `${origin}/` })
  expectEqual(stats, ['/index.html', '/index.md'])
})

Deno.test('a lookup failure that is not notFound fails the load', async () => {
  const source: NodeSource = {
    stat: () => Promise.reject(new Error('offline')),
    read: () => Promise.reject(new Error('read was called')),
  }
  const failure = await home(source).then(() => null, (error) => error)
  expectEqual(failure?.message, 'offline')
})

Deno.test('an HTML conversation attachment opens as a file, not a frame', async () => {
  const path = '/_/conversations/chat/attachments/proof.html'
  const source = space({ [path]: '<html>proof</html>' })
  source.read = () => Promise.reject(new Error('must not read attachment'))
  expectEqual(await loadNode(source, origin, path, '', 0), {
    state: 'file',
    path,
    src: origin + path,
  })
})

Deno.test('an image conversation attachment retains its image view', async () => {
  const path = '/_/conversations/chat/attachments/proof.png'
  const source = space({ [path]: '' })
  source.read = () => Promise.reject(new Error('must not read image as text'))
  expectEqual(await loadNode(source, origin, path, '', 0), {
    state: 'image',
    path,
    src: origin + path,
  })
})

Deno.test('attachment definitions and directories never enter trusted frames', async () => {
  for (const name of ['proof.view', 'proof.md', 'proof.txt', 'proof.json']) {
    const path = '/_/conversations/chat/attachments/' + name
    const source = space({
      [path]: JSON.stringify({
        sql: 'SELECT 1',
        view: 'kanban',
        config: { groupBy: 'status', cardTitle: 'title' },
      }),
    })
    source.read = () =>
      Promise.reject(new Error('must not interpret attachment'))
    expectEqual(await loadNode(source, origin, path, '', 0), {
      state: 'file',
      path,
      src: origin + path,
    })
  }
  const path = '/_/conversations/chat/attachments'
  const source: NodeSource = {
    stat: () => Promise.resolve({ kind: 'directory' }),
    read: () => Promise.reject(new Error('must not interpret attachment')),
  }
  expectEqual(await loadNode(source, origin, path, '', 0), {
    state: 'file',
    path,
    src: origin + path,
  })
})
