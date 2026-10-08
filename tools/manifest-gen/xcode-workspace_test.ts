import { assertEquals, assertThrows } from './assertions.ts'
import { parse } from '@std/yaml'
import type { AppManifest, PackageManifest } from './generate.ts'
import { takeFlagValue } from './generate.ts'
import {
  appIconSource,
  type LocalPackageRef,
  resourceSourcePath,
  targetedDeviceFamily,
  workspaceContents,
  xcodeInfoPlist,
  xcodeProjectSpec,
} from './xcode-workspace.ts'

const packages: Record<string, LocalPackageRef> = {
  'packages/example': {
    name: 'ExampleCore',
    products: ['ExampleUI', 'ExampleMacUI'],
    path: '../..',
  },
}

function shell(overrides: Partial<AppManifest> = {}): AppManifest {
  return {
    name: 'Example',
    signingTeamID: 'TEAM123456',
    targets: [
      {
        name: 'ExampleiOS',
        platform: 'iOS',
        bundleID: 'tech.example.app',
        bundleName: 'Example',
        entitlements: {},
        families: ['iphone', 'ipad'],
        appIcons: ['Resources/Mobile/Assets.xcassets/AppIcon.appiconset/**'],
        infoPlist: 'Sources/BazelInfo-iOS.plist',
        minimumOSVersion: '18.0',
        dependencies: ['//packages/example:ExampleUI'],
        info: {},
      },
    ],
    ...overrides,
  }
}

Deno.test('app icon globs resolve to the enclosing catalog and icon name', () => {
  assertEquals(
    appIconSource('Resources/Mobile/Assets.xcassets/AppIcon.appiconset/**'),
    {
      path: 'Resources/Mobile/Assets.xcassets',
      name: 'AppIcon',
    },
  )
  assertEquals(
    appIconSource(
      'Resources/TV/Assets.xcassets/App Icon & Top Shelf Image.brandassets/**',
    ),
    {
      path: 'Resources/TV/Assets.xcassets',
      name: 'App Icon & Top Shelf Image',
    },
  )
  assertEquals(
    appIconSource(
      'Resources/Vision/Assets.xcassets/AppIcon.solidimagestack/**',
    ),
    {
      path: 'Resources/Vision/Assets.xcassets',
      name: 'AppIcon',
    },
  )
  assertEquals(appIconSource('Resources/AppIcon.icon/**'), {
    path: 'Resources/AppIcon.icon',
    name: 'AppIcon',
  })
  assertEquals(appIconSource('Resources/loose/*.png'), undefined)
})

Deno.test('bundle-interior resources fold to the enclosing bundle', () => {
  assertEquals(
    resourceSourcePath('Resources/Assets.xcassets/LaunchScreen.imageset'),
    'Resources/Assets.xcassets',
  )
  assertEquals(
    resourceSourcePath('Resources/LaunchScreen.storyboard'),
    'Resources/LaunchScreen.storyboard',
  )
  assertEquals(
    resourceSourcePath('Resources/Localizations'),
    'Resources/Localizations',
  )
})

Deno.test('device families lower to Xcode identifiers, macOS to none', () => {
  assertEquals(targetedDeviceFamily(['iphone', 'ipad']), '1,2')
  assertEquals(targetedDeviceFamily(['tv']), '3')
  assertEquals(targetedDeviceFamily(['vision']), '7')
  assertEquals(targetedDeviceFamily(['watch']), '4')
  assertEquals(targetedDeviceFamily(['mac']), undefined)
})

Deno.test('watch applications become embedded companion Xcode targets', () => {
  const app = shell({
    libraries: [{ name: 'WatchLibrary', sources: 'Watch/Sources' }],
    watchApplications: [{
      name: 'ExampleWatch',
      platform: 'watchOS',
      bundleID: 'tech.example.app.watchkitapp',
      bundleName: 'Example',
      entitlements: {},
      families: ['watch'],
      appIcons: [],
      infoPlist: 'Watch/Info.plist',
      minimumOSVersion: '11.0',
      dependencies: [':WatchLibrary'],
      info: {},
    }],
  })
  app.targets[0].watchApplication = 'ExampleWatch'
  const { spec } = xcodeProjectSpec(app, packages)
  const targets = spec.targets as Record<string, Record<string, unknown>>
  assertEquals(targets.ExampleWatch.platform, 'watchOS')
  assertEquals(targets.ExampleWatch.deploymentTarget, '11.0')
  assertEquals(targets.ExampleiOS.dependencies, [
    { package: 'ExampleCore', product: 'ExampleUI' },
    { target: 'ExampleWatch' },
  ])
})

Deno.test('an app target becomes an application target linking the package product', () => {
  const { spec, unresolved } = xcodeProjectSpec(shell(), packages)
  assertEquals(unresolved, [])
  assertEquals(spec.packages, { ExampleCore: { path: '../..' } })
  const target = (spec.targets as Record<string, Record<string, unknown>>)
    .ExampleiOS
  assertEquals(target.type, 'application')
  assertEquals(target.platform, 'iOS')
  assertEquals(target.deploymentTarget, '18.0')
  assertEquals(target.dependencies, [
    { package: 'ExampleCore', product: 'ExampleUI' },
  ])
  assertEquals(target.sources, [
    { path: 'Resources/Mobile/Assets.xcassets' },
    { path: '.xcodegen/ExampleiOS-XcodeShell.swift' },
  ])
  assertEquals((target.settings as { base: Record<string, string> }).base, {
    PRODUCT_BUNDLE_IDENTIFIER: 'tech.example.app',
    PRODUCT_NAME: 'Example',
    INFOPLIST_FILE: '.xcodegen/ExampleiOS-Info.plist',
    GENERATE_INFOPLIST_FILE: 'NO',
    CODE_SIGN_ENTITLEMENTS: 'ExampleiOS-dev.entitlements',
    CODE_SIGN_STYLE: 'Manual',
    SWIFT_VERSION: '6.0',
    DEVELOPMENT_TEAM: 'TEAM123456',
    PROVISIONING_PROFILE_SPECIFIER: 'Wuhu Dev tech.example.app',
    TARGETED_DEVICE_FAMILY: '1,2',
    ASSETCATALOG_COMPILER_APPICON_NAME: 'AppIcon',
  })
})

Deno.test('app extensions become embedded Xcode targets', () => {
  const app = shell({
    libraries: [{ name: 'WidgetLibrary', sources: 'Widgets/Sources' }],
    extensions: [
      {
        name: 'ExampleWidgets',
        platform: 'iOS',
        bundleID: 'tech.example.app.widgets',
        bundleName: 'Widgets',
        entitlements: {},
        families: ['iphone', 'ipad'],
        appIcons: [],
        resources: ['Widgets/Resources'],
        infoPlist: 'Widgets/BazelInfo.plist',
        minimumOSVersion: '18.0',
        dependencies: [':WidgetLibrary'],
        info: {},
      },
    ],
  })
  app.targets[0].extensions = ['ExampleWidgets']

  const { spec } = xcodeProjectSpec(app, packages)
  const targets = spec.targets as Record<string, Record<string, unknown>>
  assertEquals(targets.ExampleWidgets.type, 'app-extension')
  assertEquals(targets.ExampleWidgets.sources, [
    { path: 'Widgets/Sources', excludes: ['**/BazelInfo*.plist'] },
    { path: 'Widgets/Resources' },
    { path: '.xcodegen/ExampleWidgets-XcodeShell.swift' },
  ])
  assertEquals(targets.ExampleiOS.dependencies, [
    { package: 'ExampleCore', product: 'ExampleUI' },
    { target: 'ExampleWidgets' },
  ])
})

Deno.test('app resources join the target sources so Xcode bundles them', () => {
  const app = shell()
  app.targets[0].resources = ['Resources/Localizations']
  const { spec } = xcodeProjectSpec(app, packages)
  const target = (spec.targets as Record<string, Record<string, unknown>>)
    .ExampleiOS
  assertEquals(target.sources, [
    { path: 'Resources/Mobile/Assets.xcassets' },
    { path: 'Resources/Localizations' },
    { path: '.xcodegen/ExampleiOS-XcodeShell.swift' },
  ])
})

Deno.test('shell libraries fold into the app target, transitively', () => {
  const app = shell({
    libraries: [
      {
        name: 'Shared',
        sources: ['Sources/Shared', 'Sources/Routes'],
        dependencies: ['//packages/example:ExampleUI'],
      },
      {
        name: 'Mobile',
        sources: 'Sources/Mobile',
        dependencies: [':Shared'],
      },
    ],
  })
  app.targets[0].dependencies = [':Mobile']
  const { spec } = xcodeProjectSpec(app, packages)
  const target = (spec.targets as Record<string, Record<string, unknown>>)
    .ExampleiOS
  assertEquals(target.sources, [
    { path: 'Sources/Mobile', excludes: ['**/BazelInfo*.plist'] },
    { path: 'Sources/Shared', excludes: ['**/BazelInfo*.plist'] },
    { path: 'Sources/Routes', excludes: ['**/BazelInfo*.plist'] },
    { path: 'Resources/Mobile/Assets.xcassets' },
    { path: '.xcodegen/ExampleiOS-XcodeShell.swift' },
  ])
  assertEquals(target.dependencies, [
    { package: 'ExampleCore', product: 'ExampleUI' },
  ])
})

Deno.test('bazel-only dependencies are reported rather than silently dropped', () => {
  const app = shell()
  app.targets[0].dependencies = [
    '//packages/example:ExampleUI',
    '@ffmpeg//:libavcodec',
    '//packages/example:NotAProduct',
  ]
  const { spec, unresolved } = xcodeProjectSpec(app, packages)
  assertEquals(unresolved, [
    'ExampleiOS: @ffmpeg//:libavcodec',
    'ExampleiOS: //packages/example:NotAProduct',
  ])
  const target = (spec.targets as Record<string, Record<string, unknown>>)
    .ExampleiOS
  assertEquals(target.dependencies, [
    { package: 'ExampleCore', product: 'ExampleUI' },
  ])
})

Deno.test('a dependency on an undeclared library is an error', () => {
  const app = shell()
  app.targets[0].dependencies = [':Missing']
  assertThrows(
    () => xcodeProjectSpec(app, packages),
    'which no library declares',
  )
})

Deno.test('sibling platform shells keep one bundle id and one team', () => {
  const app = shell()
  app.targets.push({
    ...app.targets[0],
    name: 'ExampleTV',
    platform: 'tvOS',
    families: ['tv'],
    entitlements: {},
    appIcons: ['Resources/TV/Assets.xcassets/AppIcon.brandassets/**'],
    infoPlist: 'Sources/BazelInfo-tvOS.plist',
    minimumOSVersion: '26.0',
  })
  const { spec } = xcodeProjectSpec(app, packages)
  const targets = spec.targets as Record<
    string,
    { settings: { base: Record<string, string> } }
  >
  assertEquals(
    targets.ExampleTV.settings.base.PRODUCT_BUNDLE_IDENTIFIER,
    targets.ExampleiOS.settings.base.PRODUCT_BUNDLE_IDENTIFIER,
  )
  assertEquals(targets.ExampleTV.settings.base.DEVELOPMENT_TEAM, 'TEAM123456')
  assertEquals(
    targets.ExampleTV.settings.base.PROVISIONING_PROFILE_SPECIFIER,
    'Wuhu Dev tech.example.app tvOS',
  )
  assertEquals(
    targets.ExampleiOS.settings.base.PROVISIONING_PROFILE_SPECIFIER,
    'Wuhu Dev tech.example.app iOS',
  )
})

Deno.test('a native visionOS shell never reuses the iOS profile name', () => {
  const app = shell({
    targets: [{
      ...shell().targets[0],
      name: 'ExampleVision',
      platform: 'visionOS',
      families: ['vision'],
      appIcons: [],
      infoPlist: 'Sources/BazelInfo-visionOS.plist',
      minimumOSVersion: '26.0',
    }],
  })
  const { spec } = xcodeProjectSpec(app, packages)
  const targets = spec.targets as Record<
    string,
    { settings: { base: Record<string, string> } }
  >
  assertEquals(
    targets.ExampleVision.settings.base.PROVISIONING_PROFILE_SPECIFIER,
    'Wuhu Dev tech.example.app visionOS',
  )
})

Deno.test('the workspace lists the package itself before each shell project', () => {
  assertEquals(
    workspaceContents('example', ['example/Apps/example/Example.xcodeproj']),
    `<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "group:example">
   </FileRef>
   <FileRef
      location = "group:example/Apps/example/Example.xcodeproj">
   </FileRef>
</Workspace>
`,
  )
})

Deno.test('--workspace takes its value out of the positional package list', () => {
  assertEquals(
    takeFlagValue(
      ['--apply', '--workspace', 'packages/arcroom/'],
      '--workspace',
    ),
    {
      value: 'packages/arcroom',
      rest: ['--apply'],
    },
  )
  assertEquals(takeFlagValue(['--workspace=packages/arcroom'], '--workspace'), {
    value: 'packages/arcroom',
    rest: [],
  })
  assertEquals(
    takeFlagValue(['--apply', 'packages/wuhu-core'], '--workspace'),
    {
      value: undefined,
      rest: ['--apply', 'packages/wuhu-core'],
    },
  )
  assertThrows(
    () => takeFlagValue(['--workspace', '--apply'], '--workspace'),
    'needs a package directory',
  )
})

Deno.test('xcodeInfoPlist injects CFBundleExecutable for Xcode processing', () => {
  const merged = xcodeInfoPlist({ CFBundleName: 'Example' })
  assertEquals(merged.CFBundleExecutable, '$(EXECUTABLE_NAME)')
  assertEquals(merged.CFBundleName, 'Example')
})

Deno.test('xcodeInfoPlist keeps an explicit CFBundleExecutable', () => {
  const merged = xcodeInfoPlist({ CFBundleExecutable: 'Custom' })
  assertEquals(merged.CFBundleExecutable, 'Custom')
})

Deno.test('local launch arguments land on every generated scheme', () => {
  const { spec } = xcodeProjectSpec(shell(), packages, {
    launchArguments: ['-seedLibrary /Volumes/share/arcroom-seed'],
  })
  const target = (spec.targets as Record<string, Record<string, unknown>>)
    .ExampleiOS
  assertEquals(target.scheme, {
    testTargets: [],
    commandLineArguments: {
      '-seedLibrary /Volumes/share/arcroom-seed': true,
    },
  })
})

Deno.test('no local config leaves the scheme argument-free', () => {
  const { spec } = xcodeProjectSpec(shell(), packages)
  const target = (spec.targets as Record<string, Record<string, unknown>>)
    .ExampleiOS
  assertEquals(target.scheme, { testTargets: [] })
})

Deno.test('direct macOS workspace uses its only release entitlements variant', () => {
  const app = shell()
  app.targets[0] = {
    ...app.targets[0],
    name: 'WuhuAppDirect',
    platform: 'macOS',
    distribution: 'direct',
    bundleID: 'ai.wuhu.app.direct',
    families: ['mac'],
  }
  const { spec } = xcodeProjectSpec(app, packages)
  const targets = spec.targets as Record<
    string,
    { settings: { base: Record<string, string> } }
  >
  const settings = targets.WuhuAppDirect.settings.base
  assertEquals(
    settings.CODE_SIGN_ENTITLEMENTS,
    'WuhuAppDirect-release.entitlements',
  )
  assertEquals(settings.PRODUCT_BUNDLE_IDENTIFIER, 'ai.wuhu.app.direct')
  assertEquals(settings.PROVISIONING_PROFILE_SPECIFIER, undefined)
})

Deno.test('the real direct Wuhu workspace resolves SoftwareUpdate as a package product', async () => {
  const app = parse(
    await Deno.readTextFile(
      new URL('../../packages/wuhu-app/Apps/wuhu/app.yml', import.meta.url),
    ),
  ) as AppManifest
  const pkg = parse(
    await Deno.readTextFile(
      new URL('../../packages/wuhu-app/package.yml', import.meta.url),
    ),
  ) as PackageManifest
  assertEquals(Array.isArray(pkg.products), true)
  const { spec, unresolved } = xcodeProjectSpec(app, {
    'packages/wuhu-app': {
      name: pkg.packageName,
      products: pkg.products as string[],
      path: '../..',
    },
  })
  const targets = spec.targets as Record<
    string,
    { dependencies: { package: string; product: string }[] }
  >
  assertEquals(
    targets.WuhuAppDirect.dependencies.some((dependency) =>
      dependency.package === pkg.packageName &&
      dependency.product === 'SoftwareUpdate'
    ),
    true,
  )
  assertEquals(
    unresolved.includes('WuhuAppDirect: //packages/wuhu-app:SoftwareUpdate'),
    false,
  )
})
