import { assertEquals, assertThrows } from '@std/assert'
import { testArchiveFragment, testArchiveRepos } from './archives.ts'
import { moduleFragmentRepos } from './module.ts'

const source = 'packages/p/Targets/T/target.yml'
const sha256 = 'ab'.repeat(32)

Deno.test('a test archive lowers to an http_archive with its filegroups', () => {
  const fragment = testArchiveFragment({
    corpus_repo: {
      url: 'http://host/corpus.tar.zst',
      sha256,
      filegroups: { tree: '**', index: 'dir/INDEX' },
    },
  }, source)
  assertEquals(fragment.source, source)
  assertEquals(
    fragment.text,
    `http_archive(
    name = "corpus_repo",
    build_file_content = """
package(default_visibility = ["//visibility:public"])

filegroup(
    name = "tree",
    srcs = glob(["**"]),
)

filegroup(
    name = "index",
    srcs = ["dir/INDEX"],
)
""",
    sha256 = "${sha256}",
    url = "http://host/corpus.tar.zst",
)
`,
  )
  assertEquals(moduleFragmentRepos(fragment.text), ['corpus_repo'])
})

Deno.test('every declared archive is a repository its package owns', () => {
  const archive = { url: 'u', sha256, filegroups: { all: '**' } }
  assertEquals(testArchiveRepos({ a: archive, b: archive }), ['a', 'b'])
  assertEquals(testArchiveRepos(undefined), [])
})

Deno.test('a test archive is refused without a hex sha256, filegroups or a plain file path', () => {
  const refused = (archive: Record<string, unknown>, message: string) =>
    assertThrows(
      () =>
        testArchiveFragment(
          { repo: { url: 'u', sha256, filegroups: { all: '**' }, ...archive } },
          source,
        ),
      Error,
      message,
    )
  refused({ sha256: 'ABC' }, 'archive repo needs a hex sha256')
  refused({ filegroups: {} }, 'archive repo declares no filegroups')
  refused({ filegroups: { some: '*.mp4' } }, 'must be "**"')
  refused({ filegroups: { root: '/MANIFEST' } }, 'must be "**"')
  for (
    const path of [
      '../MANIFEST',
      'dir/../MANIFEST',
      './MANIFEST',
      'dir//MANIFEST',
      'dir/',
      '',
    ]
  ) {
    refused({ filegroups: { escape: path } }, 'must be "**"')
  }
})
