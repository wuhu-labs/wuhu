import { ApiError } from '../sdk/errors.ts'
import type { ReadOutput } from './contract.gen.ts'
import { fileKind, fileOpening, openFile } from './file-opening.ts'

function expectEqual(actual: unknown, expected: unknown) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

const origin = 'https://shared.space.test'

function reading(content: string): (path: string) => Promise<ReadOutput> {
  return () => Promise.resolve({ content, token: 't1' })
}

function refusing(failure: Error): (path: string) => Promise<ReadOutput> {
  return () => Promise.reject(failure)
}

const neverRead = refusing(new Error('read was called'))

const notUTF8 = new ApiError(422, {
  code: 'unsupported',
  message: '/notes/blob.txt is not UTF-8 text',
})

Deno.test('images open as images, whatever the case of the extension', () => {
  const paths = ['/a.png', '/e/f014854.jpg', '/b.JPEG', '/c.gif', '/d.webp']
  expectEqual(paths.map(fileOpening), paths.map(() => 'image'))
  expectEqual(fileOpening('/IMG_0001.HEIC'), 'image')
})

Deno.test('known binaries open as a file card', () => {
  expectEqual(
    ['/x.zip', '/y.pdf', '/z.tar.gz', '/m.mov', '/space.sqlite'].map(
      fileOpening,
    ),
    ['file', 'file', 'file', 'file', 'file'],
  )
})

Deno.test('text and unknown extensions open as text', () => {
  expectEqual(
    ['/a.md', '/b.swift', '/Makefile', '/.gitignore', '/tls.key', '/d.jpg/e']
      .map(fileOpening),
    ['text', 'text', 'text', 'text', 'text', 'text'],
  )
})

Deno.test('the card names the kind from the extension', () => {
  expectEqual(
    ['/a/b.zip', '/c.tar.gz', '/LICENSE', '/.env'].map(fileKind),
    ['ZIP file', 'GZ file', 'File', 'File'],
  )
})

Deno.test('an image loads from the content origin without a read', async () => {
  expectEqual(
    await openFile('/e/f 1.jpg', 78684, () => origin, neverRead),
    {
      state: 'image',
      path: '/e/f 1.jpg',
      size: 78684,
      src: `${origin}/e/f%201.jpg`,
    },
  )
})

Deno.test('a known binary is a card without a read', async () => {
  expectEqual(await openFile('/b.zip', 41, () => origin, neverRead), {
    state: 'file',
    path: '/b.zip',
    size: 41,
    src: `${origin}/b.zip`,
  })
})

Deno.test('a text extension that is not UTF-8 falls back to the card', async () => {
  expectEqual(
    await openFile('/notes/blob.txt', 9, () => origin, refusing(notUTF8)),
    {
      state: 'file',
      path: '/notes/blob.txt',
      size: 9,
      src: `${origin}/notes/blob.txt`,
    },
  )
  expectEqual(
    await openFile('/a.log', 3, () => origin, reading('a\u0000b')),
    { state: 'file', path: '/a.log', size: 3, src: `${origin}/a.log` },
  )
})

Deno.test('any other read failure is still an error', async () => {
  const outage = new ApiError(503, { code: 'unavailable', message: 'down' })
  const failure = await openFile('/a.txt', 1, () => origin, refusing(outage))
    .then(() => null, (thrown: unknown) => thrown)
  expectEqual(failure === outage, true)
})

Deno.test('text files open as before and never ask for the origin', async () => {
  const noOrigin = () => {
    throw new Error('origin was asked for')
  }
  expectEqual(await openFile('/a.md', 5, noOrigin, reading('# hi')), {
    state: 'markdown',
    content: '# hi',
    path: '/a.md',
    token: 't1',
  })
  expectEqual(await openFile('/a.txt', 2, noOrigin, reading('hi')), {
    state: 'text',
    content: 'hi',
  })
})

Deno.test('without a content origin an image is a card with no download', async () => {
  expectEqual(await openFile('/a.png', 1, () => null, neverRead), {
    state: 'file',
    path: '/a.png',
    size: 1,
    src: null,
  })
  expectEqual(await openFile('/a.png', 1, () => undefined, neverRead), {
    state: 'loading',
  })
})
