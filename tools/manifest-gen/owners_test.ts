import { join } from '@std/path'
import { assertEquals, assertThrows } from './assertions.ts'
import {
  assertOwner,
  assertPublicEdges,
  discoverOwnedPackages,
  type OwnedPackage,
  owningPackageDir,
  publicPackageDirs,
  referencedLabelPackages,
} from './owners.ts'
import { moduleFragmentRepos } from './module.ts'

Deno.test('an owner outside the law-2 vocabulary is rejected', () => {
  assertOwner('wuhu', 'p/package.yml')
  assertThrows(() => assertOwner(undefined, 'p/package.yml'), 'p/package.yml')
  assertThrows(() => assertOwner('nobuyclub', 'p/package.yml'), 'nobuyclub')
})

Deno.test('labels reduce to their package path wherever they sit', () => {
  assertEquals(
    referencedLabelPackages({
      dependencies: ['Fetch', '//packages/wuhu-web/app:bundle', '@quickjs//:x'],
      embedded: [{ target: '//packages/wuhu-core:Targets/X/y.json' }],
    }),
    ['packages/wuhu-web/app', '@quickjs', 'packages/wuhu-core'],
  )
})

Deno.test('a module fragment declares the names of its top-level calls', () => {
  assertEquals(
    moduleFragmentRepos(
      [
        'http_archive(',
        '    name = "ffmpeg",',
        '    build_file_content = """',
        'cc_library(',
        '    name = "libavcodec",',
        ')',
        '""",',
        ')',
        '',
        'http_archive(',
        '    name = "libsmb2",',
        ')',
      ].join('\n'),
    ),
    ['ffmpeg', 'libsmb2'],
  )
})

Deno.test('an external repository belongs to the package whose fragment declares it', () => {
  const packages: OwnedPackage[] = [
    {
      dir: 'packages/core',
      owner: 'wuhu',
      references: ['@ffmpeg', '@quickjs'],
    },
    {
      dir: 'packages/media',
      owner: 'arcroom',
      references: ['@ffmpeg'],
      repos: ['ffmpeg'],
    },
  ]
  assertThrows(
    () => assertPublicEdges(packages),
    'packages/core (owner wuhu) -> packages/media (owner arcroom) via @ffmpeg',
  )
  assertPublicEdges([{ ...packages[0], references: ['@quickjs'] }, packages[1]])
})

Deno.test('a label resolves to the innermost manifest directory', () => {
  const dirs = ['packages/web', 'packages/web/app', 'packages/core']
  assertEquals(owningPackageDir('packages/web/app', dirs), 'packages/web/app')
  assertEquals(owningPackageDir('packages/web/ui/x', dirs), 'packages/web')
  assertEquals(owningPackageDir('packages/cored', dirs), undefined)
})

Deno.test('a public package may not reach a non-public one', () => {
  assertThrows(
    () =>
      assertPublicEdges([
        { dir: 'packages/core', owner: 'wuhu', references: ['packages/kit'] },
        { dir: 'packages/kit', owner: 'wuhu-app', references: [] },
      ]),
    'packages/core (owner wuhu) -> packages/kit (owner wuhu-app)',
  )
})

Deno.test('private packages may reach public ones, and self-references pass', () => {
  assertPublicEdges([
    {
      dir: 'packages/app',
      owner: 'wuhu-app',
      references: ['packages/core', 'packages/lab'],
    },
    { dir: 'packages/lab', owner: 'internal', references: [] },
    {
      dir: 'packages/core',
      owner: 'wuhu',
      references: ['packages/core', 'packages/json'],
    },
    { dir: 'packages/json', owner: 'shared', references: [] },
  ])
})

Deno.test('a reference outside every manifest fails loudly', () => {
  assertThrows(
    () =>
      assertPublicEdges([
        { dir: 'packages/core', owner: 'wuhu', references: ['packages/gone'] },
      ]),
    'inside no package manifest',
  )
})

async function writeFile(root: string, path: string, text: string) {
  const full = join(root, path)
  await Deno.mkdir(join(full, '..'), { recursive: true })
  await Deno.writeTextFile(full, text)
}

Deno.test('discovery reads Swift and deno owners and their edges', async () => {
  const root = await Deno.makeTempDir()
  try {
    await writeFile(
      root,
      'core/package.yml',
      'name: core\nowner: wuhu\nexternalPackages:\n  json:\n    path: ../json\n    products: [JSONValue]\n',
    )
    await writeFile(
      root,
      'core/Targets/Server/target.yml',
      'name: Server\nembeddedResources:\n  - target: //packages/web/app:bundle\n',
    )
    await writeFile(root, 'json/package.yml', 'name: json\nowner: shared\n')
    await writeFile(
      root,
      'json/MODULE.fragment.bazel',
      'http_archive(\n    name = "corpus",\n)\n',
    )
    await writeFile(
      root,
      'web/deno.json',
      '{"owner":"wuhu","workspace":["./app","./lab"],"links":["../resolver"]}',
    )
    await writeFile(root, 'web/app/deno.json', '{"owner":"wuhu"}')
    await writeFile(root, 'web/lab/deno.json', '{"owner":"wuhu-app"}')
    await writeFile(root, 'resolver/deno.json', '{"owner":"shared"}')
    const packages = await discoverOwnedPackages(root)
    const byDir = new Map(packages.map((pkg) => [pkg.dir, pkg]))
    assertEquals(byDir.get(join(root, 'core'))?.references, [
      join(root, 'json'),
      'packages/web/app',
    ])
    assertEquals(byDir.get(join(root, 'json'))?.repos, ['corpus'])
    assertEquals(byDir.get(join(root, 'web'))?.references, [
      join(root, 'web/app'),
      join(root, 'web/lab'),
      join(root, 'resolver'),
    ])
    assertEquals(byDir.get(join(root, 'web/lab'))?.references, [
      join(root, 'web'),
    ])
    assertEquals(
      publicPackageDirs(packages),
      ['core', 'json', 'resolver', 'web', 'web/app'].map((dir) =>
        join(root, dir)
      ),
    )
    // A private member of a public workspace ships with it: `deno install`
    // in any member needs every member's sources.
    assertThrows(
      () =>
        assertPublicEdges(
          packages.filter((pkg) => pkg.dir !== join(root, 'core')),
        ),
      `${join(root, 'web')} (owner wuhu) -> ${join(root, 'web/lab')}`,
    )
  } finally {
    await Deno.remove(root, { recursive: true })
  }
})

Deno.test('an app shell carries its package owner', async () => {
  const root = await Deno.makeTempDir()
  try {
    await writeFile(root, 'kit/package.yml', 'name: kit\nowner: internal\n')
    await writeFile(root, 'kit/Apps/lab/app.yml', 'name: Lab\nowner: wuhu\n')
    let message = ''
    try {
      await discoverOwnedPackages(root)
    } catch (error) {
      message = String(error)
    }
    assertEquals(message.includes('has its owner'), true)
  } finally {
    await Deno.remove(root, { recursive: true })
  }
})
