import { assertEquals, assertIncludes, assertThrows } from './assertions.ts'
import {
  configureFragmentRepo,
  pinnedRepos,
  renderModuleBazel,
} from './module.ts'

const template = `module(name = "t")

{{package_modules}}

swift_deps = use_extension("//x:e.bzl", "swift_deps")
{{swift_deps_configure}}
use_repo(
    swift_deps,
{{swift_deps_repos}}
)
`

function configure(repo: string, name = repo) {
  return {
    source: `bazel/umbrella/configure/${repo}.bazel`,
    text: `swift_deps.configure_package(\n    name = "${name}",\n)\n`,
  }
}

Deno.test('pinned repos follow the rspm naming of each pin identity', () => {
  assertEquals(
    [
      ...pinnedRepos(JSON.stringify({
        pins: [{ identity: 'swift-clocks' }, { identity: 'tca26' }],
      })),
    ],
    ['swiftpkg_swift_clocks', 'swiftpkg_tca26'],
  )
})

Deno.test('a configure fragment must configure the repo it is named for', () => {
  assertEquals(
    configureFragmentRepo(configure('swiftpkg_tca26')),
    'swiftpkg_tca26',
  )
  assertThrows(
    () => configureFragmentRepo(configure('swiftpkg_tca26', 'swiftpkg_other')),
    'must hold exactly one configure_package for swiftpkg_tca26',
  )
})

Deno.test('only configure fragments for pinned repos are rendered', () => {
  const rendered = renderModuleBazel({
    template,
    swiftDepsRepos: ['swift_package', 'swiftpkg_swift_clocks'],
    packageModules: [{
      source: 'packages/a/MODULE.fragment.bazel',
      text: 'http_archive(name = "a")\n',
    }],
    configure: [
      configure('swiftpkg_swift_clocks'),
      configure('swiftpkg_tca26'),
    ],
    pinned: new Set(['swiftpkg_swift_clocks']),
    strict: false,
  })
  assertIncludes(
    rendered,
    '# From packages/a/MODULE.fragment.bazel.\nhttp_archive(name = "a")\n',
  )
  assertIncludes(rendered, 'name = "swiftpkg_swift_clocks"')
  assertEquals(rendered.includes('swiftpkg_tca26'), false)
  assertIncludes(
    rendered,
    '    swift_deps,\n    "swift_package",\n    "swiftpkg_swift_clocks",\n)',
  )
})

Deno.test('the whole-repo render rejects a fragment for an unpinned repo', () => {
  assertThrows(
    () =>
      renderModuleBazel({
        template,
        swiftDepsRepos: ['swift_package'],
        packageModules: [],
        configure: [configure('swiftpkg_tca26')],
        pinned: new Set(),
        strict: true,
      }),
    'which bazel/umbrella/Package.resolved does not pin',
  )
})

Deno.test('empty fragment lists leave no blank runs behind', () => {
  const rendered = renderModuleBazel({
    template,
    swiftDepsRepos: ['swift_package'],
    packageModules: [],
    configure: [],
    pinned: new Set(),
    strict: true,
  })
  assertEquals(rendered.includes('\n\n\n'), false)
  assertEquals(rendered.includes('{{'), false)
})

Deno.test('a template missing a placeholder is rejected', () => {
  assertThrows(
    () =>
      renderModuleBazel({
        template: template.replace('{{package_modules}}', ''),
        swiftDepsRepos: [],
        packageModules: [],
        configure: [],
        pinned: new Set(),
        strict: true,
      }),
    'must contain {{package_modules}} exactly once',
  )
})
