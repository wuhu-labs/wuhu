import { join } from '@std/path'
import { assertEquals } from './assertions.ts'
import { manifestInputPaths } from './provenance.ts'

Deno.test('provenance covers module fragments and configure fragments', async () => {
  const root = await Deno.makeTempDir()
  try {
    for (
      const path of [
        'MODULE.bazel.template',
        'bazel/umbrella/Package.resolved',
        'bazel/umbrella/configure/swiftpkg_x.bazel',
        'deno.json',
        'deno.lock',
        'packages/media/MODULE.fragment.bazel',
        'packages/media/Sources/Media.swift',
        'packages/media/package.yml',
        'tools/manifest-gen/generate.ts',
      ]
    ) {
      await Deno.mkdir(join(root, path, '..'), { recursive: true })
      await Deno.writeTextFile(join(root, path), '')
    }
    assertEquals(await manifestInputPaths(root), [
      'MODULE.bazel.template',
      'bazel/umbrella/Package.resolved',
      'bazel/umbrella/configure/swiftpkg_x.bazel',
      'deno.json',
      'deno.lock',
      'packages/media/MODULE.fragment.bazel',
      'packages/media/package.yml',
      'tools/manifest-gen/generate.ts',
    ])
  } finally {
    await Deno.remove(root, { recursive: true })
  }
})
