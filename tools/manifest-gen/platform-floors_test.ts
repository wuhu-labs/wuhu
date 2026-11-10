import { assertEquals, assertStringIncludes, assertThrows } from '@std/assert'
import {
  type AppManifest,
  generateAppBuildBazel,
  generateBuildBazel,
  packageFloorEdges,
  type PackageManifest,
  type TargetKind,
  type TargetManifest,
} from './generate.ts'
import {
  assertFloorEdges,
  comparePlatformVersions,
  laneFloorsBazelrcContent,
  lowestFloors,
} from './platform-floors.ts'

// The umbrella's floor must satisfy the strictest package, and two products
// shipping to different OS floors must not be forced to agree.
Deno.test('comparePlatformVersions orders numerically, not lexically', () => {
  assertEquals(comparePlatformVersions('26.0', '9.0') > 0, true)
  assertEquals(comparePlatformVersions('15.0', '26.0') < 0, true)
  assertEquals(comparePlatformVersions('18.4', '18.10') < 0, true)
  assertEquals(comparePlatformVersions('26', '26.0'), 0)
})

Deno.test('each lane, and every bare build on a Mac, compiles at the lowest floor any package or app declares', () => {
  const floors = lowestFloors([
    {
      floors: { iOS: '18.4', macOS: '15.4', tvOS: '26.0' },
      location: 'a/package.yml',
    },
    { floors: { tvOS: '18.10', visionOS: '26.0' }, location: 'b/package.yml' },
    { floors: { tvOS: '18.4' }, location: 'b/app.yml' },
    { floors: { watchOS: '11.0' }, location: 'c/app.yml' },
  ])
  assertEquals(
    laneFloorsBazelrcContent(floors).split('\n').filter((line) =>
      line.startsWith('common')
    ),
    [
      'common --macos_minimum_os=15.4',
      'common:mac --macos_minimum_os=15.4',
      'common:ios --ios_minimum_os=18.4',
      'common:ios-device --ios_minimum_os=18.4',
      'common:tvos --tvos_minimum_os=18.4',
      'common:tvos-device --tvos_minimum_os=18.4',
      'common:visionos --minimum_os_version=26.0',
      'common:visionos-device --minimum_os_version=26.0',
      'common:watchos --watchos_minimum_os=11.0',
      'common:watchos-device --watchos_minimum_os=11.0',
    ],
  )
  assertThrows(
    () => lowestFloors([{ floors: { macCatalyst: '18.0' }, location: 'x' }]),
    Error,
    'x declares unknown platforms: macCatalyst',
  )
})

const pkg: PackageManifest = {
  name: 'P',
  owner: 'shared',
  swiftToolsVersion: '6.3',
  packageName: 'PKit',
  platforms: { iOS: '18.4', macOS: '15.4', tvOS: '26.0', visionOS: '26.0' },
  checks: {
    build: ['linux', 'mac', 'ios', 'tvos', 'visionos'],
    test: ['linux', 'mac'],
  },
}

function target(name: string, kind: TargetKind): TargetManifest {
  return { name, kind, sources: 'Sources', manifestDir: `Targets/${name}` }
}

function rule(build: string, kind: string, name: string): string {
  const start = build.indexOf(`${kind}(\n    name = "${name}",`)
  if (start < 0) throw new Error(`no ${kind} ${name} in:\n${build}`)
  return build.slice(start, build.indexOf('\n)\n', start) + 3)
}

Deno.test('every package target compiles against the package floor of each platform', async () => {
  const build = await generateBuildBazel(pkg, [
    { ...target('Lib', 'library'), tests: {} },
    { ...target('tool', 'executable'), stamp: true },
    target('CLib', 'cLibrary'),
  ])
  assertStringIncludes(build.split('\n')[0], '"wuhu_platform_floor"')
  assertEquals(
    rule(build, 'wuhu_platform_floor', 'platform_floor'),
    'wuhu_platform_floor(\n    name = "platform_floor",\n    macos = "15.4",\n    ios = "18.4",\n    tvos = "26.0",\n    visionos = "26.0",\n)\n',
  )
  for (
    const [kind, name] of [
      ['wuhu_swift_library', 'Lib'],
      ['wuhu_swift_test', 'LibTests'],
      ['wuhu_swift_binary', 'tool'],
      ['wuhu_swift_binary', 'tool_unstamped'],
      ['wuhu_c_library', 'CLib'],
    ]
  ) {
    assertStringIncludes(
      rule(build, kind, name),
      '    platform_floor = ":platform_floor",\n',
    )
  }
})

Deno.test('a package without floors and a mac XCTest bundle take no floor target', async () => {
  const bare = await generateBuildBazel(
    { ...pkg, platforms: undefined, checks: { build: ['linux'] } },
    [target('Lib', 'library')],
  )
  assertEquals(bare.includes('platform_floor'), false)

  const bundled = await generateBuildBazel(pkg, [{
    ...target('Lib', 'library'),
    tests: { macBundle: true, checks: { test: ['mac'] } },
  }])
  const bundle = rule(bundled, 'wuhu_macos_test', 'LibTests')
  assertStringIncludes(bundle, 'minimum_os_version = "15.4"')
  assertEquals(bundle.includes('platform_floor'), false)
})

Deno.test('an app shell library compiles at the lowest minimum of the bundles that link it', () => {
  const bundle = {
    bundleName: 'Example',
    entitlements: {},
    appIcons: [],
    infoPlist: 'Sources/BazelInfo.plist',
    info: {},
  }
  const app: AppManifest = {
    name: 'Example',
    viewPilot: false,
    libraries: [
      { name: 'Shared', sources: 'Sources' },
      { name: 'MacOnly', sources: 'Mac' },
    ],
    targets: [
      {
        ...bundle,
        name: 'ExampleMac',
        platform: 'macOS',
        bundleID: 'ms.liu.example',
        families: ['mac'],
        minimumOSVersion: '15.4',
        dependencies: [':Shared', ':MacOnly'],
      },
      {
        ...bundle,
        name: 'ExampleTV',
        platform: 'tvOS',
        bundleID: 'ms.liu.example',
        families: ['tv'],
        minimumOSVersion: '26.0',
        dependencies: [':Shared'],
      },
    ],
  }
  const build = generateAppBuildBazel(app)
  assertStringIncludes(
    rule(build, 'wuhu_platform_floor', 'Shared.platform_floor'),
    '    macos = "15.4",\n    tvos = "26.0",\n',
  )
  assertEquals(
    rule(build, 'wuhu_platform_floor', 'MacOnly.platform_floor').includes(
      'tvos',
    ),
    false,
  )
  const shared = rule(build, 'swift_library', 'Shared')
  assertStringIncludes(shared, ' + ["@$(location :Shared.platform_floor)"],')
  assertStringIncludes(shared, 'swiftc_inputs = [":Shared.platform_floor"],')
})

Deno.test('an importer floored below a dependency is refused, on the platforms the importer declares', () => {
  const floors = new Map([
    ['packages/dep', { iOS: '26.0', macOS: '15.4', tvOS: '27.0' }],
  ])
  assertFloorEdges(floors, [
    {
      location: 'packages/user/package.yml',
      floors: { iOS: '26.0', macOS: '15.4' },
      dependsOn: ['packages/dep', 'packages/unfloored'],
    },
  ])
  const error = assertThrows(() =>
    assertFloorEdges(floors, [
      {
        location: 'packages/user/package.yml',
        floors: { iOS: '18.4', macOS: '15.4' },
        dependsOn: ['packages/dep'],
      },
    ])
  )
  assertStringIncludes(
    (error as Error).message,
    'packages/user/package.yml (iOS 18.4) imports packages/dep (iOS 26.0)',
  )
  assertEquals((error as Error).message.includes('macOS'), false)
})

Deno.test('a package imports its path packages, labelled packages and the HMR runtime; a bundle what it links and what the generator injects', () => {
  const bundle = {
    bundleName: 'Example',
    entitlements: {},
    appIcons: [],
    infoPlist: 'Sources/BazelInfo.plist',
    info: {},
    bundleID: 'ms.liu.example',
  }
  const app: AppManifest = {
    name: 'Example',
    hmr: true,
    libraries: [
      { name: 'Shell', sources: 'Sources', dependencies: [':Core'] },
      {
        name: 'Core',
        sources: 'Core',
        dependencies: ['//packages/kit:Kit', ':Model'],
      },
      { name: 'Unused', sources: 'Unused', dependencies: ['//packages/x:X'] },
    ],
    targets: [{
      ...bundle,
      name: 'ExampleMac',
      platform: 'macOS',
      families: ['mac'],
      minimumOSVersion: '15.4',
      dependencies: [':Shell'],
    }],
  }
  const [library, shell] = packageFloorEdges(
    'packages/p',
    {
      ...pkg,
      externalPackages: { dep: { path: '../dep', products: ['Dep'] } },
    },
    [{
      ...target('Lib', 'library'),
      hmr: true,
      dependencies: ['//packages/labelled:L'],
    }],
    [{ app, location: 'packages/p/Apps/example/app.yml' }],
  )
  assertEquals(library.floors, pkg.platforms)
  assertEquals(library.dependsOn, [
    'packages/dep',
    'packages/labelled',
    'packages/hmr',
  ])
  assertEquals(shell, {
    location: 'packages/p/Apps/example/app.yml ExampleMac',
    floors: { macOS: '15.4' },
    dependsOn: [
      'packages/kit',
      'packages/p',
      'packages/hmr',
      'packages/view-pilot',
    ],
  })
})
