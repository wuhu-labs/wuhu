import { prepareAttachment } from './image-intake.ts'
import { type DraftFile, draftKey, Drafts, type FileVault } from './drafts.ts'

function assertEquals<T>(actual: T, expected: T): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    )
  }
}

type Encoding = {
  width: number
  height: number
  type: string
  quality?: number
}

async function withCodec(
  size: (encoding: Encoding) => number,
  run: (encodings: Encoding[], draws: number[]) => Promise<void>,
  dimensions = [3000, 1500],
  decodeGate: Promise<void> = Promise.resolve(),
) {
  const originals = {
    Image: Object.getOwnPropertyDescriptor(globalThis, 'Image'),
    document: Object.getOwnPropertyDescriptor(globalThis, 'document'),
  }
  const encodings: Encoding[] = []
  const draws: number[] = []
  class DecodedImage {
    naturalWidth = dimensions[0]
    naturalHeight = dimensions[1]
    src = ''
    decode() {
      const type = fetchType.get(this.src)
      return [
          'image/gif',
          'image/webp',
          'image/png',
          'image/jpeg',
          'image/svg+xml',
          'application/octet-stream',
        ].includes(type!)
        ? decodeGate
        : Promise.reject(new Error('unsupported format'))
    }
  }
  const createURL = URL.createObjectURL
  const revokeURL = URL.revokeObjectURL
  const fetchType = new Map<string, string>()
  URL.createObjectURL = (blob) => {
    const url = createURL(blob)
    fetchType.set(url, (blob as Blob).type)
    return url
  }
  URL.revokeObjectURL = (url) => {
    fetchType.delete(url)
    revokeURL(url)
  }
  Object.defineProperty(globalThis, 'Image', {
    configurable: true,
    value: DecodedImage,
  })
  Object.defineProperty(globalThis, 'document', {
    configurable: true,
    value: {
      createElement: () => ({
        width: 0,
        height: 0,
        getContext: () => ({ drawImage: () => draws.push(1) }),
        toBlob(
          this: { width: number; height: number },
          done: (blob: Blob) => void,
          type: string,
          quality?: number,
        ) {
          const encoding = {
            width: this.width,
            height: this.height,
            type,
            quality,
          }
          encodings.push(encoding)
          done(new Blob([new Uint8Array(size(encoding))], { type }))
        },
      }),
    },
  })
  try {
    await run(encodings, draws)
    assertEquals(fetchType.size, 0)
  } finally {
    URL.createObjectURL = createURL
    URL.revokeObjectURL = revokeURL
    for (const key of ['Image', 'document'] as const) {
      const descriptor = originals[key]
      if (descriptor) Object.defineProperty(globalThis, key, descriptor)
      else Reflect.deleteProperty(globalThis, key)
    }
  }
}

Deno.test('GIF and WebP use PNG at the fitted edge, regardless of source size', async () => {
  await withCodec(() => 100, async (encodings, draws) => {
    for (const type of ['image/gif', 'image/webp']) {
      const original = new File(['small'], `picture.${type.split('/')[1]}`, {
        type,
      })
      const fitted = await prepareAttachment(original)
      assertEquals([fitted.name, fitted.type, fitted.size], [
        'picture.png',
        'image/png',
        100,
      ])
    }
    assertEquals(
      encodings.map(({ width, height, type }) => [width, height, type]),
      [
        [2048, 1024, 'image/png'],
        [2048, 1024, 'image/png'],
      ],
    )
    assertEquals(draws.length, 2)
  })
})

Deno.test('fitting uses the app’s PNG-first edge and JPEG-quality ladder', async () => {
  await withCodec(
    ({ width, type, quality }) =>
      width === 1280 && type === 'image/jpeg' && quality === 0.6
        ? 3 * 1024 * 1024
        : 3 * 1024 * 1024 + 1,
    async (encodings, draws) => {
      const fitted = await prepareAttachment(
        new File(['pixels'], 'picture.webp', { type: 'image/webp' }),
      )
      assertEquals([fitted.name, fitted.type, fitted.size], [
        'picture.jpg',
        'image/jpeg',
        3 * 1024 * 1024,
      ])
      assertEquals(
        encodings.map((
          { width, height, type, quality },
        ) => [width, height, type, quality ?? null]),
        [
          [2048, 1024, 'image/png', null],
          [2048, 1024, 'image/jpeg', 0.85],
          [2048, 1024, 'image/jpeg', 0.6],
          [2048, 1024, 'image/jpeg', 0.4],
          [1280, 640, 'image/png', null],
          [1280, 640, 'image/jpeg', 0.85],
          [1280, 640, 'image/jpeg', 0.6],
        ],
      )
      assertEquals(draws.length, 2)
    },
  )
})

Deno.test('an undecodable HEIC or other file keeps its name and bytes', async () => {
  await withCodec(() => 100, async (encodings) => {
    for (
      const [name, type] of [['photo.heic', 'image/heic'], [
        'design.psd',
        'image/vnd.adobe.photoshop',
      ], ['notes.txt', 'text/plain']]
    ) {
      const original = new File(['undecodable'], name, { type })
      assertEquals(await prepareAttachment(original) === original, true)
    }
    assertEquals(encodings, [])
  })
})

Deno.test('a decodable image that cannot fit reports the byte limit', async () => {
  await withCodec(() => 3 * 1024 * 1024 + 1, async (encodings) => {
    let refusal = ''
    try {
      await prepareAttachment(
        new File(['pixels'], 'large.gif', { type: 'image/gif' }),
      )
    } catch (error) {
      refusal = (error as Error).message
    }
    assertEquals(refusal, 'large.gif: that image will not fit under 3 MB.')
    assertEquals(encodings.at(-1), {
      width: 800,
      height: 400,
      type: 'image/jpeg',
      quality: 0.4,
    })
  })
})

Deno.test('a small decoded image is not upscaled', async () => {
  await withCodec(() => 100, async (encodings) => {
    await prepareAttachment(
      new File(['pixels'], 'small.webp', { type: 'image/webp' }),
    )
    assertEquals(encodings, [{ width: 24, height: 16, type: 'image/png' }])
  }, [24, 16])
})

function draftStore(restored: DraftFile[] = []): Drafts {
  const items = new Map<string, string>()
  const shelf: Storage = {
    get length() {
      return items.size
    },
    clear: () => items.clear(),
    getItem: (key) => items.get(key) ?? null,
    key: (index) => [...items.keys()][index] ?? null,
    removeItem: (key) => {
      items.delete(key)
    },
    setItem: (key, value) => {
      items.set(key, value)
    },
  }
  if (restored.length > 0) {
    shelf.setItem(
      draftKey('s', 'a'),
      JSON.stringify({ text: 'restored', reply: null, savedAt: 0 }),
    )
  }
  const vault: FileVault = {
    read: () => Promise.resolve(restored),
    write: () => Promise.resolve(),
    remove: () => Promise.resolve(),
    sweep: () => Promise.resolve(),
  }
  return new Drafts('s', shelf, vault, () => 0)
}

function ready(drafts: Drafts, target: string): Promise<void> {
  return new Promise((resolve) => {
    const stop = drafts.subscribe(() => {
      if (!drafts.get(target).preparing) {
        stop()
        resolve()
      }
    })
    if (!drafts.get(target).preparing) {
      stop()
      resolve()
    }
  })
}

Deno.test('restored GIFs pass the draft choke point before take can release them', async () => {
  await withCodec(() => 100, async () => {
    const gif = new File(['GIF89a'], 'restored.gif', { type: 'image/gif' })
    const drafts = draftStore([{ id: 'saved', file: gif }])
    assertEquals(drafts.get('a').preparing, true)
    assertEquals(drafts.take('a'), null)
    await ready(drafts, 'a')
    const outgoing = drafts.take('a')!
    assertEquals([
      outgoing.text,
      outgoing.files[0].file.name,
      outgoing.files[0].file.type,
    ], ['restored', 'restored.png', 'image/png'])
  })
})

Deno.test('remounting a target cannot send text ahead of its preparing image', async () => {
  let finish!: () => void
  const gate = new Promise<void>((resolve) => {
    finish = resolve
  })
  await withCodec(
    () => 100,
    async () => {
      const drafts = draftStore()
      drafts.update('a', (draft) => ({ ...draft, text: 'with image' }))
      drafts.attach('a', [
        new File(['GIF89a'], 'picked.gif', { type: 'image/gif' }),
      ])
      const unmount = drafts.subscribe(() => {})
      unmount()
      drafts.get('b')
      const remounted = drafts.get('a')
      assertEquals([remounted.text, remounted.preparing, drafts.take('a')], [
        'with image',
        true,
        null,
      ])
      finish()
      await ready(drafts, 'a')
      const outgoing = drafts.take('a')!
      assertEquals([
        outgoing.text,
        outgoing.files[0].file.name,
        drafts.get('a').files.length,
      ], ['with image', 'picked.png', 0])
    },
    [3000, 1500],
    gate,
  )
})

Deno.test('the draft choke point preserves small PNG/JPEG signatures and SVG documents', async () => {
  await withCodec(() => 100, async (encodings) => {
    const originals = [
      new File(
        [Uint8Array.of(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)],
        'wrong-png-name.bin',
        { type: 'application/octet-stream' },
      ),
      new File([Uint8Array.of(0xff, 0xd8, 0xff)], 'wrong-jpeg-name.bin', {
        type: 'application/octet-stream',
      }),
      new File(['<svg xmlns="http://www.w3.org/2000/svg"/>'], 'vector.svg', {
        type: 'image/svg+xml',
      }),
    ]
    const drafts = draftStore()
    drafts.attach('a', originals)
    await ready(drafts, 'a')
    const outgoing = drafts.take('a')!
    assertEquals(outgoing.files.map((held, i) => held.file === originals[i]), [
      true,
      true,
      true,
    ])
    assertEquals(encodings, [])
  })
})

Deno.test('a failed image does not discard its successful batch siblings', async () => {
  await withCodec(() => 3 * 1024 * 1024 + 1, async () => {
    const text = new File(['notes'], 'notes.txt', { type: 'text/plain' })
    const drafts = draftStore()
    drafts.attach('a', [
      new File(['GIF89a'], 'large.gif', { type: 'image/gif' }),
      text,
    ])
    await ready(drafts, 'a')
    assertEquals(
      drafts.get('a').refusal,
      'large.gif: that image will not fit under 3 MB.',
    )
    assertEquals(drafts.take('a')!.files.map((held) => held.file === text), [
      true,
    ])
  })
})

Deno.test('clearing during conversion cannot put the image into the next draft', async () => {
  let finish!: () => void
  const gate = new Promise<void>((resolve) => {
    finish = resolve
  })
  await withCodec(
    () => 100,
    async () => {
      const drafts = draftStore()
      drafts.attach('a', [
        new File(['GIF89a'], 'removed.gif', { type: 'image/gif' }),
      ])
      drafts.clear('a')
      drafts.update('a', (draft) => ({ ...draft, text: 'next draft' }))
      finish()
      await new Promise((resolve) => setTimeout(resolve, 0))
      assertEquals([
        drafts.get('a').text,
        drafts.get('a').files.length,
        drafts.get('a').preparing,
      ], ['next draft', 0, false])
    },
    [3000, 1500],
    gate,
  )
})
