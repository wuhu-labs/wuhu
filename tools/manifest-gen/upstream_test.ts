import { assertEquals, assertRejects, assertThrows } from '@std/assert'
import { join } from '@std/path'
import {
  type CTargetLowering,
  ensureUpstreamCheckout,
  validateCTarget,
} from './upstream.ts'

const base: CTargetLowering = {
  module: 'CFixture',
  fetch: {
    url: 'https://invalid.test/fixture.tar.gz',
    sha256: '',
    stripPrefix: 'upstream',
  },
  sources: ['src'],
  publicHeadersPath: 'src/include',
}

async function fixture(
  run: (f: {
    root: string
    c: CTargetLowering
    fetch: () => Promise<Uint8Array>
    fetched: () => number
  }) => Promise<void>,
  link = false,
  archiveRoot = 'upstream',
): Promise<void> {
  const root = await Deno.makeTempDir()
  try {
    await Deno.mkdir(join(root, 'upstream/src/include'), { recursive: true })
    await Deno.writeTextFile(
      join(root, 'upstream/src/include/value.h'),
      'one\n',
    )
    await Deno.writeTextFile(
      join(root, 'upstream/src/include/module.modulemap'),
      'module CFixture { header "value.h" export * }\n',
    )
    await Deno.mkdir(join(root, 'upstream/Xbox 360'), { recursive: true })
    await Deno.writeTextFile(
      join(root, 'upstream/Xbox 360/quotes" colon: trailing '),
      'preserved\n',
    )
    if (link) await Deno.symlink('/tmp', join(root, 'upstream/link'))
    const git = await new Deno.Command('git', {
      args: ['init', '--quiet', root],
      stderr: 'piped',
    }).output()
    assertEquals(git.success, true)
    const archive = join(root, 'fixture.tar.gz')
    const result = await new Deno.Command('tar', {
      args: ['-czf', archive, '-C', root, archiveRoot],
      stderr: 'piped',
    }).output()
    assertEquals(result.success, true)
    const bytes = await Deno.readFile(archive)
    const hash = await digest(bytes)
    let fetched = 0
    await run({
      root,
      c: { ...base, fetch: { ...base.fetch, sha256: hash } },
      fetch: () => {
        fetched++
        return Promise.resolve(bytes)
      },
      fetched: () => fetched,
    })
  } finally {
    await Deno.remove(root, { recursive: true })
  }
}

function patch(
  before: string,
  after: string,
  path = 'src/include/value.h',
): string {
  return `--- a/${path}\n+++ b/${path}\n@@ -1 +1 @@\n-${before}\n+${after}\n`
}
const tree = (root: string) => join(root, '.upstream/CFixture')
const marker = (root: string) => join(tree(root), '.materialized-sha256')

Deno.test('cTarget metadata rejects ambiguous headers, escaping paths, duplicates and bad strip counts', () => {
  for (
    const c of [
      { ...base, publicHeader: 'value.h' },
      { ...base, publicHeadersPath: undefined },
      { ...base, module: '../outside' },
      { ...base, publicHeadersPath: '/outside' },
      { ...base, sources: ['../outside'] },
      { ...base, headerSearchPaths: ['a/../../outside'] },
      { ...base, fetch: { ...base.fetch, stripPrefix: '../outside' } },
      ...['../bad.patch', '/bad.patch', 'a\\bad.patch'].map((path) => ({
        ...base,
        patches: [{ path, strip: 1 }],
      })),
      ...[-1, 0.5, NaN].map((strip) => ({
        ...base,
        patches: [{ path: 'p.patch', strip }],
      })),
      {
        ...base,
        patches: [{ path: 'p.patch', strip: 1 }, { path: 'p.patch', strip: 0 }],
      },
    ]
  ) assertThrows(() => validateCTarget(c))
})

Deno.test('cTarget preserves nested headers/modulemap, applies ordered patches and keys cache by bytes', async () => {
  await fixture(async (f) => {
    await Deno.writeTextFile(join(f.root, 'first.patch'), patch('one', 'two'))
    await Deno.writeTextFile(
      join(f.root, 'second.patch'),
      patch('two', 'three'),
    )
    const c = {
      ...f.c,
      patches: [{ path: 'first.patch', strip: 1 }, {
        path: 'second.patch',
        strip: 1,
      }],
    }
    await ensureUpstreamCheckout(f.root, c, f.fetch)
    assertEquals(
      await Deno.readTextFile(join(tree(f.root), 'src/include/value.h')),
      'three\n',
    )
    assertEquals(
      await Deno.readTextFile(
        join(tree(f.root), 'src/include/module.modulemap'),
      ),
      'module CFixture { header "value.h" export * }\n',
    )
    assertEquals(
      await Deno.readTextFile(
        join(tree(f.root), 'Xbox 360/quotes" colon: trailing '),
      ),
      'preserved\n',
    )
    const original = await Deno.readTextFile(marker(f.root))
    await ensureUpstreamCheckout(f.root, c, f.fetch)
    assertEquals(f.fetched(), 1)
    await Deno.writeTextFile(join(f.root, 'second.patch'), patch('two', 'four'))
    await ensureUpstreamCheckout(f.root, c, f.fetch)
    assertEquals(f.fetched(), 2)
    assertEquals(
      await Deno.readTextFile(join(tree(f.root), 'src/include/value.h')),
      'four\n',
    )
    assertEquals(original === await Deno.readTextFile(marker(f.root)), false)
    await assertRejects(() =>
      ensureUpstreamCheckout(f.root, {
        ...c,
        patches: [...c.patches].reverse(),
      }, f.fetch)
    )
    await assertRejects(() => Deno.stat(marker(f.root)), Deno.errors.NotFound)
    assertEquals(
      await Deno.readTextFile(join(tree(f.root), 'src/include/value.h')),
      'four\n',
    )
    await ensureUpstreamCheckout(f.root, c, f.fetch)
    assertEquals(f.fetched(), 4)
    await assertRejects(() =>
      ensureUpstreamCheckout(f.root, {
        ...c,
        patches: [{ path: 'first.patch', strip: 0 }],
      }, f.fetch)
    )
    await assertRejects(() => Deno.stat(marker(f.root)), Deno.errors.NotFound)
    const leftovers = []
    for await (const entry of Deno.readDir(join(f.root, '.upstream'))) {
      leftovers.push(entry.name)
    }
    assertEquals(leftovers, ['CFixture'])
  })
})

Deno.test('cTarget supports new-file patches, strip zero and legacy header copying', async () => {
  await fixture(async (f) => {
    await Deno.writeTextFile(
      join(f.root, 'new.patch'),
      '--- /dev/null\n+++ glue/config.h\n@@ -0,0 +1 @@\n+#define FIXTURE 1\n',
    )
    const c = {
      ...f.c,
      publicHeadersPath: undefined,
      publicHeader: 'glue/config.h',
      patches: [{ path: 'new.patch', strip: 0 }],
    }
    await ensureUpstreamCheckout(f.root, c, f.fetch)
    assertEquals(
      await Deno.readTextFile(join(tree(f.root), 'include/glue/config.h')),
      '#define FIXTURE 1\n',
    )
    await ensureUpstreamCheckout(f.root, {
      ...c,
      publicHeader: undefined,
      publicHeadersPath: 'src/include',
    }, f.fetch)
    assertEquals(f.fetched(), 2)
    await assertRejects(
      () => Deno.stat(join(tree(f.root), 'include')),
      Deno.errors.NotFound,
    )
  })
})

Deno.test('cTarget rejects checksum mismatch, wrong prefix, missing headers and linked archives', async () => {
  await fixture(async (f) => {
    for (
      const c of [
        { ...f.c, fetch: { ...f.c.fetch, sha256: 'bad' } },
        { ...f.c, fetch: { ...f.c.fetch, stripPrefix: 'wrong' } },
        { ...f.c, publicHeadersPath: 'missing' },
      ]
    ) {
      await assertRejects(() => ensureUpstreamCheckout(f.root, c, f.fetch))
      await assertRejects(() => Deno.stat(tree(f.root)), Deno.errors.NotFound)
    }
  })
  await fixture(async (f) => {
    await assertRejects(
      () => ensureUpstreamCheckout(f.root, f.c, f.fetch),
      Error,
      'no links',
    )
  }, true)
})

Deno.test('cTarget invalidates cache on missing, escaping, fuzzy or reversed patches', async () => {
  await fixture(async (f) => {
    for (
      const contents of [
        undefined,
        patch('one', 'two', '../../outside'),
        '--- a/src/include/value.h\n+++ b/src/include/value.h\n@@ -1,2 +1,2 @@\n missing-context\n-one\n+two\n',
        patch('two', 'one'),
        'diff --git a/link b/link\nnew file mode 120000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+/tmp\n',
      ]
    ) {
      await ensureUpstreamCheckout(f.root, f.c, f.fetch)
      if (contents !== undefined) {
        await Deno.writeTextFile(join(f.root, 'bad.patch'), contents)
      }
      await assertRejects(() =>
        ensureUpstreamCheckout(f.root, {
          ...f.c,
          patches: [{ path: 'bad.patch', strip: 1 }],
        }, f.fetch)
      )
      await assertRejects(() => Deno.stat(marker(f.root)), Deno.errors.NotFound)
      assertEquals(
        await Deno.readTextFile(join(tree(f.root), 'src/include/value.h')),
        'one\n',
      )
    }
  })
})

Deno.test('cTarget refuses patch symlinks escaping package and checkout symlinks', async () => {
  await fixture(async (f) => {
    const outside = await Deno.makeTempFile()
    try {
      await Deno.writeTextFile(outside, patch('one', 'two'))
      await Deno.symlink(outside, join(f.root, 'escape.patch'))
      await assertRejects(() =>
        ensureUpstreamCheckout(f.root, {
          ...f.c,
          patches: [{ path: 'escape.patch', strip: 1 }],
        }, f.fetch)
      )
      await Deno.symlink(join(f.root, 'upstream'), tree(f.root))
      await assertRejects(
        () => ensureUpstreamCheckout(f.root, f.c, f.fetch),
        Error,
        'symlink',
      )
      assertEquals(f.fetched(), 0)
    } finally {
      await Deno.remove(outside)
    }
  })
})

Deno.test('cTarget rebuilds legacy/schema markers and never publishes failed staging', async () => {
  await fixture(async (f) => {
    await ensureUpstreamCheckout(f.root, f.c, f.fetch)
    const value = join(tree(f.root), 'src/include/value.h')
    for (const stale of ['old-schema-identity', f.c.fetch.sha256]) {
      await Deno.writeTextFile(marker(f.root), stale)
      await ensureUpstreamCheckout(f.root, f.c, f.fetch)
    }
    assertEquals(f.fetched(), 3)
    await Deno.remove(marker(f.root))
    await Deno.writeTextFile(
      join(tree(f.root), '.fetched-sha256'),
      f.c.fetch.sha256,
    )
    await ensureUpstreamCheckout(f.root, f.c, f.fetch)
    assertEquals(f.fetched(), 4)
    await assertRejects(
      () =>
        ensureUpstreamCheckout(f.root, {
          ...f.c,
          fetch: { ...f.c.fetch, url: 'https://invalid.test/changed.tar.gz' },
        }, async () => {
          assertEquals(await Deno.readTextFile(value), 'one\n')
          await assertRejects(
            () => Deno.stat(marker(f.root)),
            Deno.errors.NotFound,
          )
          throw new Error('injected fetch failure')
        }),
      Error,
      'injected fetch failure',
    )
    assertEquals(await Deno.readTextFile(value), 'one\n')
    await assertRejects(() => Deno.stat(marker(f.root)), Deno.errors.NotFound)
  })
})

Deno.test('cTarget patch parsing distinguishes hunk text from file headers', async () => {
  await fixture(async (f) => {
    await Deno.writeTextFile(
      join(f.root, 'first.patch'),
      patch('one', '-- counter;'),
    )
    await Deno.writeTextFile(
      join(f.root, 'second.patch'),
      patch('-- counter;', '++ counter;'),
    )
    await ensureUpstreamCheckout(f.root, {
      ...f.c,
      patches: [
        { path: 'first.patch', strip: 1 },
        { path: 'second.patch', strip: 1 },
      ],
    }, f.fetch)
    assertEquals(
      await Deno.readTextFile(join(tree(f.root), 'src/include/value.h')),
      '++ counter;\n',
    )
  })
})

async function digest(bytes: Uint8Array): Promise<string> {
  return [
    ...new Uint8Array(
      await crypto.subtle.digest('SHA-256', bytes as Uint8Array<ArrayBuffer>),
    ),
  ]
    .map((b) => b.toString(16).padStart(2, '0')).join('')
}

async function changeFirstTarEntry(
  bytes: Uint8Array,
  name: string,
  type: string,
): Promise<Uint8Array> {
  const tar = new Uint8Array(
    await new Response(
      new Blob([bytes as Uint8Array<ArrayBuffer>]).stream().pipeThrough(
        new DecompressionStream('gzip'),
      ),
    ).arrayBuffer(),
  )
  const encoder = new TextEncoder()
  tar.fill(0, 0, 100)
  tar.set(encoder.encode(name), 0)
  tar[156] = type.charCodeAt(0)
  tar.fill(0, 157, 257)
  if (type === '1') tar.set(encoder.encode('upstream/src/include/value.h'), 157)
  tar.fill(32, 148, 156)
  const sum = tar.slice(0, 512).reduce((a, b) => a + b, 0)
  tar.set(encoder.encode(sum.toString(8).padStart(6, '0') + '\0 '), 148)
  return new Uint8Array(
    await new Response(
      new Blob([tar]).stream().pipeThrough(new CompressionStream('gzip')),
    ).arrayBuffer(),
  )
}

Deno.test('cTarget confines archive names and rejects hardlinks and special entries before extraction', async () => {
  await fixture(async (f) => {
    const original = await f.fetch()
    for (
      const [name, type] of [
        [join(f.root, 'outside'), '5'],
        ['../outside', '5'],
        ['upstream/../outside', '5'],
        ['upstream/./outside', '5'],
        ['upstream//outside', '5'],
        ['upstream/back\\slash', '5'],
        ['upstream/new\nline', '5'],
        ['upstream/tab\tname', '5'],
        ['upstream/carriage\rreturn', '5'],
        ['upstream/escape\x1bname', '5'],
        ['upstream/delete\x7fname', '5'],
        ['upstream/double//', '5'],
        ['upstream/link', '1'],
        ['upstream/fifo', '6'],
      ]
    ) {
      const bytes = await changeFirstTarEntry(original, name!, type!)
      const c = {
        ...f.c,
        fetch: {
          ...f.c.fetch,
          sha256: await digest(bytes),
          stripPrefix: undefined,
        },
      }
      await assertRejects(() =>
        ensureUpstreamCheckout(f.root, c, () => Promise.resolve(bytes))
      )
      await assertRejects(() => Deno.stat(tree(f.root)), Deno.errors.NotFound)
      await assertRejects(
        () => Deno.stat(join(f.root, 'outside')),
        Deno.errors.NotFound,
      )
    }
  })
})

Deno.test('cTarget strips the exact multi-component archive prefix', async () => {
  await fixture(
    async (f) => {
      await ensureUpstreamCheckout(f.root, {
        ...f.c,
        sources: ['include'],
        publicHeadersPath: 'include',
        fetch: { ...f.c.fetch, stripPrefix: 'upstream/src' },
      }, f.fetch)
      assertEquals(
        await Deno.readTextFile(join(tree(f.root), 'include/value.h')),
        'one\n',
      )
    },
    false,
    'upstream/src',
  )
})

Deno.test('cTarget C++ standard accepts only the implemented pinned requirement', () => {
  validateCTarget({ ...base, cxxStandard: 'c++17' })
  for (
    const cxxStandard of [
      'c++14',
      'gnu++17',
      'c++20',
      '',
      '-std=c++17',
      17,
      null,
    ]
  ) {
    assertThrows(
      () =>
        validateCTarget({ ...base, cxxStandard } as unknown as CTargetLowering),
      Error,
      'Unsupported cTarget cxxStandard',
    )
  }
})

Deno.test('cTarget tar subprocesses ignore inherited listing and extraction options', async () => {
  await fixture(async (f) => {
    const previous = Deno.env.get('TAR_OPTIONS')
    Deno.env.set('TAR_OPTIONS', '--unsupported-materializer-option')
    try {
      await ensureUpstreamCheckout(f.root, f.c, f.fetch)
      assertEquals(
        await Deno.readTextFile(join(tree(f.root), 'src/include/value.h')),
        'one\n',
      )
    } finally {
      if (previous === undefined) Deno.env.delete('TAR_OPTIONS')
      else Deno.env.set('TAR_OPTIONS', previous)
    }
  })
})
