import { assertEquals, assertThrows } from '@std/assert'
import { dropVersion, resolveSpecifier } from './core.ts'
import type { ResolverWorkspace } from './core.ts'

const workspace: ResolverWorkspace = {
  root: '/w',
  packages: [
    {
      name: undefined,
      dir: '/w/app',
      imports: { '~/': './src/', 'react': 'npm:react@19' },
      exports: {},
    },
    {
      name: '@wuhu/ui',
      dir: '/w/ui',
      imports: {},
      exports: { '.': './src/mod.ts', './tokens.css': './src/tokens.css' },
    },
    {
      name: '@wuhu/ui-icons',
      dir: '/w/icons',
      imports: {},
      exports: { '.': './mod.ts' },
    },
  ],
}

Deno.test('a mapped prefix resolves inside the importing package', () => {
  assertEquals(resolveSpecifier(workspace, '~/lib/a.ts', '/w/app/src/x.ts'), {
    kind: 'local',
    path: '/w/app/src/lib/a.ts',
  })
})

Deno.test('a bare import-map key matches exactly, never as a prefix', () => {
  assertEquals(resolveSpecifier(workspace, 'react', '/w/app/src/x.ts'), {
    kind: 'npm',
    specifier: 'react',
  })
  // `react-dom` must not be captured by the `react` key.
  assertEquals(
    resolveSpecifier(workspace, 'react-dom', '/w/app/src/x.ts'),
    null,
  )
})

Deno.test('a peer package resolves through its exports map', () => {
  assertEquals(resolveSpecifier(workspace, '@wuhu/ui', '/w/app/src/x.ts'), {
    kind: 'peer',
    packageName: '@wuhu/ui',
    path: '/w/ui/src/mod.ts',
  })
  assertEquals(
    resolveSpecifier(workspace, '@wuhu/ui/tokens.css', '/w/app/src/x.ts'),
    { kind: 'peer', packageName: '@wuhu/ui', path: '/w/ui/src/tokens.css' },
  )
})

Deno.test('the longest matching peer name wins', () => {
  assertEquals(
    resolveSpecifier(workspace, '@wuhu/ui-icons', '/w/app/src/x.ts'),
    { kind: 'peer', packageName: '@wuhu/ui-icons', path: '/w/icons/mod.ts' },
  )
})

Deno.test('an unknown export of a known peer is an error, not a miss', () => {
  assertThrows(
    () => resolveSpecifier(workspace, '@wuhu/ui/nope', '/w/app/src/x.ts'),
    Error,
    'does not export',
  )
})

Deno.test('an ordinary npm specifier is not ours', () => {
  assertEquals(resolveSpecifier(workspace, 'zod', '/w/app/src/x.ts'), null)
})

Deno.test('an importer outside every package is not ours', () => {
  assertEquals(
    resolveSpecifier(workspace, '@wuhu/ui', '/elsewhere/x.ts'),
    null,
  )
})

Deno.test('relative and absolute specifiers are left to vite', () => {
  assertEquals(resolveSpecifier(workspace, './a.ts', '/w/app/src/x.ts'), null)
  assertEquals(resolveSpecifier(workspace, '/a.ts', '/w/app/src/x.ts'), null)
})

Deno.test('literal npm: specifiers drop their version like mapped ones', () => {
  assertEquals(resolveSpecifier(workspace, 'npm:react@19', '/w/app/src/x.ts'), {
    kind: 'npm',
    specifier: 'react',
  })
  assertEquals(dropVersion('@scope/pkg@1.2.3/sub'), '@scope/pkg/sub')
})

Deno.test('jsr specifiers are rejected rather than silently dropped', () => {
  assertThrows(
    () => resolveSpecifier(workspace, 'jsr:@std/assert', '/w/app/src/x.ts'),
    Error,
    'not resolvable through vite',
  )
})
