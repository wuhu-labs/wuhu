import {
  appBundleInfo,
  appBundles,
  appEmbedsViewPilot,
  type AppManifest,
  appSigningTeamID,
  assertLockfileHonorsPins,
  assertNoMacroProductExport,
  assertNoViewPilotDependency,
  bazelIgnore,
  bazelPackageFromPath,
  bazelRepoFromUrl,
  collectLoweredDependencies,
  combineBuildBazel,
  comparePlatformVersions,
  discoverAppDirs,
  type ExternalPackage,
  generateAppBuildBazel,
  generateBuildBazel,
  generateDenoBuildBazel,
  generatePackageSwift,
  isRemovableLegacyPackages,
  mergeLoads,
  type PackageManifest,
  partitionBazelDeps,
  pilotInfo,
  pilotPersistedLibrarySubsystems,
  populateAppBundleInfo,
  productTargetLabel,
  productTargets,
  rawLabelLowering,
  requiresPublicHeaderMaterialization,
  resolvedEntitlements,
  swiftPMIdentityFromUrl,
  type TargetKind,
  type TargetManifest,
  validateAppEntitlements,
  validateAppExtensions,
  validateAppIntents,
  validateAppRelease,
  validateAppTransportSecurity,
  validateTargetInfo,
  validateTargetLinkedFrameworks,
  validateTargetRelease,
  variantBundle,
  viewPilotProducts,
} from './generate.ts'
import { join } from '@std/path'
import { parse } from '@std/yaml'
import { assertEquals, assertIncludes, assertThrows } from './assertions.ts'

Deno.test('ViewPilot defaults on, opt-out is honored, and previews cannot opt out', () => {
  const target: AppManifest['targets'][number] = {
    name: 'Example',
    platform: 'iOS',
    bundleID: 'tech.example.app',
  } as AppManifest['targets'][number]
  assertEquals(appEmbedsViewPilot({ name: 'Example', targets: [target] }), true)
  assertEquals(
    appEmbedsViewPilot({
      name: 'Example',
      viewPilot: false,
      targets: [target],
    }),
    false,
  )
  assertEquals(
    appEmbedsViewPilot({
      name: 'Preview',
      viewPilot: false,
      targets: [{ ...target, bundleID: 'tech.lakeridge.previews.example' }],
    }),
    true,
  )
})

Deno.test('a release shell that opts out of ViewPilot names it in no configuration', () => {
  const build = generateAppBuildBazel({
    name: 'Example',
    viewPilot: false,
    release: { name: 'example', platforms: ['ios'] },
    targets: [{
      name: 'ExampleiOS',
      platform: 'iOS',
      bundleID: 'tech.example.app',
      bundleName: 'Example',
      entitlements: {},
      families: ['iphone'],
      appIcons: [],
      infoPlist: 'Sources/BazelInfo.plist',
      minimumOSVersion: '18.0',
      dependencies: [],
      info: {},
    }],
  })
  if (build.includes('view-pilot')) {
    throw new Error('a ViewPilot opt-out shell still reaches ViewPilot')
  }
})

Deno.test('a target that names ViewPilot fails generation', () => {
  const library: TargetManifest = {
    name: 'CommonUI',
    kind: 'library',
    sources: 'Sources',
    manifestDir: 'packages/wuhu-app/Targets/CommonUI',
    dependencies: ['ViewPilot'],
  }
  assertThrows(
    () =>
      assertNoViewPilotDependency('packages/wuhu-app', [library], [], [
        'ViewPilot',
      ]),
    'packages/wuhu-app target CommonUI declares a dependency on ViewPilot',
  )

  // A raw label is the same leak spelled differently.
  assertThrows(
    () =>
      assertNoViewPilotDependency(
        'packages/wuhu-app',
        [{
          ...library,
          dependencies: ['//packages/view-pilot:ViewPilotBootstrap'],
        }],
        [],
        ['ViewPilot'],
      ),
    'target CommonUI declares a dependency on ViewPilot',
  )

  assertThrows(
    () =>
      assertNoViewPilotDependency(
        'packages/wuhu-app',
        [{
          ...library,
          dependencies: [],
          tests: { dependencies: ['ViewPilot'] },
        }],
        [],
        ['ViewPilot'],
      ),
    'target CommonUI declares a dependency on ViewPilot',
  )

  assertNoViewPilotDependency('packages/view-pilot', [library], [], [
    'ViewPilot',
  ])
})

Deno.test('only a shell that embeds ViewPilot may name it', () => {
  const bundle = {
    name: 'ExampleiOS',
    platform: 'iOS',
    bundleID: 'tech.example.app',
    dependencies: ['//packages/view-pilot:ViewPilot'],
  } as AppManifest['targets'][number]

  assertNoViewPilotDependency('packages/gika', [], [{
    name: 'Example',
    targets: [bundle],
  }], ['ViewPilot'])

  assertThrows(
    () =>
      assertNoViewPilotDependency('packages/gika', [], [{
        name: 'Example',
        viewPilot: false,
        targets: [bundle],
      }], ['ViewPilot']),
    'packages/gika app bundle ExampleiOS declares a dependency on ViewPilot',
  )
})

Deno.test('ViewPilot plist additions preserve app-authored log preferences', () => {
  const target: AppManifest['targets'][number] = {
    name: 'ExampleiOS',
    platform: 'iOS',
    bundleID: 'tech.example.app',
    bundleName: 'Example',
    entitlements: {},
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Info.plist',
    minimumOSVersion: '18.0',
    dependencies: [],
    info: {
      OSLogPreferences: {
        'tech.example.existing': {
          'DEFAULT-OPTIONS': { Level: { Enable: 'Info' } },
        },
      },
    },
  }
  const info = pilotInfo(target)
  const preferences = info.OSLogPreferences as Record<string, unknown>

  assertEquals('tech.example.existing' in preferences, true)
  assertEquals('tech.example.app' in preferences, true)
  assertEquals('tech.lakeridge.view-pilot' in preferences, true)
  for (const subsystem of pilotPersistedLibrarySubsystems) {
    assertEquals(subsystem in preferences, true)
  }
  assertEquals(
    info.NSLocalNetworkUsageDescription,
    'This development build exposes an in-process UI pilot on this device.',
  )

  assertThrows(
    () => pilotInfo({ ...target, info: { OSLogPreferences: 'invalid' } }),
    'OSLogPreferences must be a dictionary',
  )
  assertThrows(
    () => pilotInfo({ ...target, info: { OSLogPreferences: null as never } }),
    'OSLogPreferences must be a dictionary',
  )
})

Deno.test('generated app BUILD embeds ViewPilot only in the development signing graph', () => {
  const target: AppManifest['targets'][number] = {
    name: 'ExampleiOS',
    platform: 'iOS',
    bundleID: 'tech.example.app',
    bundleName: 'Example',
    entitlements: {},
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Sources/BazelInfo.plist',
    minimumOSVersion: '18.0',
    dependencies: [],
    info: {},
  }
  const build = generateAppBuildBazel({
    name: 'Example',
    release: { name: 'example', platforms: ['ios'] },
    targets: [target],
  })
  assertIncludes(
    build,
    '"//bazel/signing:dev": [\n            "//packages/view-pilot:ViewPilot",\n            "//packages/view-pilot:ViewPilotBootstrap",',
  )
  assertIncludes(
    build,
    '"//bazel/signing:store": ["Sources/BazelInfo-release.plist"]',
  )
  if (
    build.includes(
      '"//bazel/signing:store": ["//packages/view-pilot:ViewPilot"]',
    )
  ) {
    throw new Error('store branch reaches ViewPilot')
  }
})

Deno.test('app signing variant selects profiles and generated entitlements at build time', () => {
  const target: AppManifest['targets'][number] = {
    name: 'ExampleiOS',
    platform: 'iOS',
    bundleID: 'tech.example.app',
    bundleName: 'Example',
    entitlements: {},
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Sources/BazelInfo.plist',
    minimumOSVersion: '18.0',
    dependencies: [],
    info: {},
  }
  const build = generateAppBuildBazel(
    {
      name: 'Example',
      signingTeamID: 'TEAM123456',
      release: { name: 'example', platforms: ['ios'] },
      targets: [target],
    },
    ['ExampleiOS-dev.entitlements', 'ExampleiOS-release.entitlements'],
    'Apps/example',
  )
  assertIncludes(
    build,
    'profile_name = "Wuhu Store tech.example.app"',
  )
  assertIncludes(
    build,
    '"//bazel/signing:dev": "Apps/example/ExampleiOS-dev.entitlements"',
  )
  assertIncludes(
    build,
    '"//bazel/signing:store": ":ExampleiOS_store_profile__run_deno_task_prepare_profiles"',
  )
  assertIncludes(build, 'tags = ["manual"]')
  assertIncludes(build, '"//bazel/signing:store_unsigned": None,')
  assertIncludes(
    build,
    '"//bazel/signing:dev_simulator": None,\n        "//bazel/signing:dev": ":ExampleiOS_dev_profile',
  )
  assertIncludes(
    build,
    '"//bazel/signing:store_simulator": None,\n        "//bazel/signing:store": ":ExampleiOS_store_profile',
  )
})

Deno.test('native platforms select their complete profile-backed variants', () => {
  const mac: AppManifest['targets'][number] = {
    name: 'ExampleMac',
    platform: 'macOS',
    bundleID: 'tech.example.app',
    bundleName: 'Example',
    entitlements: {},
    families: ['mac'],
    appIcons: [],
    infoPlist: 'Info-Mac.plist',
    minimumOSVersion: '15.0',
    dependencies: [],
    info: {},
  }
  const ios: AppManifest['targets'][number] = {
    ...mac,
    name: 'ExampleiOS',
    platform: 'iOS',
    families: ['iphone'],
    infoPlist: 'Info-iOS.plist',
    minimumOSVersion: '18.0',
  }
  const tv: AppManifest['targets'][number] = {
    ...mac,
    name: 'ExampleTV',
    platform: 'tvOS',
    families: ['tv'],
    infoPlist: 'Info-tvOS.plist',
    minimumOSVersion: '18.0',
  }
  const vision: AppManifest['targets'][number] = {
    ...mac,
    name: 'ExampleVision',
    platform: 'visionOS',
    families: ['vision'],
    infoPlist: 'Info-visionOS.plist',
    minimumOSVersion: '26.0',
  }
  const build = generateAppBuildBazel(
    {
      name: 'Example',
      signingTeamID: 'TEAM123456',
      release: { name: 'example', platforms: ['mac', 'ios'] },
      targets: [mac, ios, tv, vision],
    },
    [
      'ExampleMac-dev.entitlements',
      'ExampleMac-release.entitlements',
      'ExampleiOS-dev.entitlements',
      'ExampleiOS-release.entitlements',
      'ExampleTV-dev.entitlements',
      'ExampleTV-release.entitlements',
      'ExampleVision-dev.entitlements',
      'ExampleVision-release.entitlements',
    ],
    'Apps/example',
  )
  assertIncludes(build, 'profile_name = "Wuhu Store tech.example.app macOS"')
  assertIncludes(build, 'profile_name = "Wuhu Dev tech.example.app iOS"')
  assertIncludes(build, 'profile_name = "Wuhu Dev tech.example.app tvOS"')
  assertIncludes(
    build,
    'profile_name = "Wuhu Dev tech.example.app visionOS"',
  )
  assertIncludes(build, 'profile_name = "Wuhu Dev tech.example.app macOS"')
  assertIncludes(
    build,
    '"//bazel/signing:dev": ":ExampleMac_dev_profile',
  )
  assertIncludes(
    build,
    '"//bazel/signing:adhoc": None,\n        "//bazel/signing:store": ":ExampleMac_store_profile',
  )
  for (const absent of ['ExampleMac_adhoc_profile']) {
    if (build.includes(absent)) {
      throw new Error(`did not expect a ${absent} target`)
    }
  }
})

Deno.test('a devIdentity signs dev and adhoc as a second app beside store', () => {
  const app: AppManifest = {
    name: 'Example',
    signingTeamID: 'TEAM123456',
    release: { name: 'example', platforms: ['ios'] },
    extensions: [{
      name: 'ExampleWidgets',
      platform: 'iOS',
      bundleID: 'tech.example.app.Widgets',
      bundleName: 'Widgets',
      entitlements: {
        common: { 'com.apple.security.application-groups': ['group.example'] },
      },
      devIdentity: {
        bundleID: 'tech.example.app.dev.Widgets',
        entitlements: {
          'com.apple.security.application-groups': ['group.example.dev'],
        },
      },
      families: ['iphone'],
      appIcons: [],
      infoPlist: 'Widgets/Info.plist',
      minimumOSVersion: '18.0',
      dependencies: [],
      info: {},
    }],
    targets: [{
      name: 'ExampleiOS',
      platform: 'iOS',
      bundleID: 'tech.example.app',
      bundleName: 'Example',
      entitlements: {
        common: { 'com.apple.security.application-groups': ['group.example'] },
        dev: { 'aps-environment': 'development' },
        release: { 'aps-environment': 'production' },
      },
      devIdentity: {
        bundleID: 'tech.example.app.dev',
        displayName: 'Example Dev',
        appIcons: ['Dev/AppIcon.icon/**'],
        entitlements: {
          'com.apple.security.application-groups': ['group.example.dev'],
        },
        info: { CFBundleURLTypes: [{ CFBundleURLSchemes: ['example-dev'] }] },
      },
      families: ['iphone'],
      appIcons: ['AppIcon.icon/**'],
      infoPlist: 'Sources/Info.plist',
      minimumOSVersion: '18.0',
      dependencies: [],
      extensions: ['ExampleWidgets'],
      info: { CFBundleURLTypes: [{ CFBundleURLSchemes: ['example'] }] },
    }],
  }
  validateAppEntitlements(app, 'app.yml')
  populateAppBundleInfo(app)
  const build = generateAppBuildBazel(app, undefined, 'Apps/example')
  assertIncludes(
    build,
    'bundle_id = select({\n        "//bazel/signing:dev": "tech.example.app.dev",\n        "//bazel/signing:adhoc": "tech.example.app.dev",\n        "//bazel/signing:store": "tech.example.app",\n    })',
  )
  assertIncludes(
    build,
    '"//bazel/signing:adhoc": "Apps/example/ExampleiOS-adhoc.entitlements"',
  )
  assertIncludes(
    build,
    '"//bazel/signing:store": "Apps/example/ExampleiOS-release.entitlements"',
  )
  assertIncludes(
    build,
    '"//bazel/signing:adhoc": ["Apps/example/Sources/Info-adhoc.plist"]',
  )
  assertIncludes(
    build,
    '"//bazel/signing:dev": ["Apps/example/Widgets/Info.plist"],\n        "//bazel/signing:adhoc": ["Apps/example/Widgets/Info.plist"],\n        "//bazel/signing:store": ["Apps/example/Widgets/Info-release.plist"]',
  )
  assertIncludes(
    build,
    '"//bazel/signing:adhoc": glob(["Apps/example/Dev/AppIcon.icon/**"])',
  )
  for (
    const name of [
      'Wuhu Dev tech.example.app.dev',
      'Wuhu AdHoc tech.example.app.dev',
      'Wuhu Store tech.example.app',
      'Wuhu AdHoc tech.example.app.dev.Widgets',
      'Wuhu Store tech.example.app.Widgets',
    ]
  ) assertIncludes(build, `profile_name = "${name}"`)
  if (build.includes('profile_name = "Wuhu Dev tech.example.app"')) {
    throw new Error('store identity must not get a Dev profile')
  }

  const target = app.targets[0]!
  assertEquals(resolvedEntitlements(target, 'adhoc', 'TEAM123456'), {
    'com.apple.security.application-groups': ['group.example.dev'],
    'aps-environment': 'production',
    'application-identifier': 'TEAM123456.tech.example.app.dev',
    'com.apple.developer.team-identifier': 'TEAM123456',
  })
  assertEquals(
    resolvedEntitlements(target, 'store', 'TEAM123456')[
      'application-identifier'
    ],
    'TEAM123456.tech.example.app',
  )
  assertEquals(target.info.CFBundleIdentifier, 'tech.example.app')
  assertEquals(
    target.devIdentity?.info?.CFBundleIdentifier,
    'tech.example.app.dev',
  )
  assertEquals(target.devIdentity?.info?.CFBundleDisplayName, 'Example Dev')
  assertEquals(target.devIdentity?.info?.CFBundleURLTypes, [
    { CFBundleURLSchemes: ['example-dev'] },
  ])
})

Deno.test('a devIdentity must cover the whole app and extend its bundle ID', () => {
  const extension = {
    name: 'ExampleWidgets',
    platform: 'iOS' as const,
    bundleID: 'tech.example.app.Widgets',
    bundleName: 'Widgets',
    entitlements: {},
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Widgets/Info.plist',
    minimumOSVersion: '18.0',
    dependencies: [],
    info: {},
  }
  const app = (
    extensionIdentity: string | undefined,
  ): AppManifest => ({
    name: 'Example',
    extensions: [{
      ...extension,
      devIdentity: extensionIdentity === undefined
        ? undefined
        : { bundleID: extensionIdentity },
    }],
    targets: [{
      ...extension,
      name: 'ExampleiOS',
      bundleID: 'tech.example.app',
      bundleName: 'Example',
      infoPlist: 'Info.plist',
      devIdentity: { bundleID: 'tech.example.app.dev' },
      extensions: ['ExampleWidgets'],
    }],
  })
  assertThrows(
    () => validateAppEntitlements(app(undefined), 'app.yml'),
    'must both declare a devIdentity or neither',
  )
  assertThrows(
    () => validateAppEntitlements(app('tech.example.other.Widgets'), 'app.yml'),
    'must extend tech.example.app.dev',
  )
  validateAppEntitlements(app('tech.example.app.dev.Widgets'), 'app.yml')
})

Deno.test('an iOS preview builds adhoc on the wildcard AdHoc profile', () => {
  const preview: AppManifest['targets'][number] = {
    name: 'ExamplePreviewiOS',
    platform: 'iOS',
    bundleID: 'tech.lakeridge.previews.example',
    bundleName: 'ExamplePreview',
    entitlements: {},
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Sources/Info.plist',
    minimumOSVersion: '18.0',
    dependencies: [],
    info: {},
  }
  const build = generateAppBuildBazel(
    { name: 'ExamplePreview', signingTeamID: 'TEAM123456', targets: [preview] },
    undefined,
    'Apps/example-preview',
  )
  assertIncludes(build, 'profile_name = "Wuhu AdHoc Previews"')
  assertIncludes(
    build,
    '"//bazel/signing:adhoc": "Apps/example-preview/ExamplePreviewiOS-release.entitlements"',
  )
  assertEquals(resolvedEntitlements(preview, 'adhoc', 'TEAM123456'), {
    'application-identifier': 'TEAM123456.tech.lakeridge.previews.example',
    'com.apple.developer.team-identifier': 'TEAM123456',
  })
})

Deno.test('entitlement overlays inject only variant-owned signing values', () => {
  const target: AppManifest['targets'][number] = {
    name: 'ExampleiOS',
    platform: 'iOS',
    bundleID: 'tech.example.app',
    bundleName: 'Example',
    entitlements: {
      common: {
        'com.apple.developer.icloud-services': ['CloudKit'],
      },
      dev: {
        'aps-environment': 'development',
        'com.apple.developer.icloud-container-environment': 'Development',
      },
      release: { 'aps-environment': 'production' },
    },
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Info.plist',
    minimumOSVersion: '18.0',
    dependencies: [],
    info: {},
  }
  assertEquals(resolvedEntitlements(target, 'dev', 'TEAM123456'), {
    'com.apple.developer.icloud-services': ['CloudKit'],
    'aps-environment': 'development',
    'com.apple.developer.icloud-container-environment': 'Development',
    'application-identifier': 'TEAM123456.tech.example.app',
    'get-task-allow': true,
  })
  assertEquals(resolvedEntitlements(target, 'store', 'TEAM123456'), {
    'com.apple.developer.icloud-services': ['CloudKit'],
    'aps-environment': 'production',
    'application-identifier': 'TEAM123456.tech.example.app',
    'com.apple.developer.team-identifier': 'TEAM123456',
    'com.apple.developer.icloud-container-environment': 'Production',
  })
  assertEquals(
    resolvedEntitlements({ ...target, platform: 'tvOS' }, 'dev', 'TEAM123456'),
    {
      'com.apple.developer.icloud-services': ['CloudKit'],
      'aps-environment': 'development',
      'com.apple.developer.icloud-container-environment': 'Development',
      'application-identifier': 'TEAM123456.tech.example.app',
      'get-task-allow': true,
    },
  )
  assertEquals(
    resolvedEntitlements({ ...target, platform: 'macOS' }, 'dev', 'TEAM123456'),
    {
      'com.apple.developer.icloud-services': ['CloudKit'],
      'aps-environment': 'development',
      'com.apple.developer.icloud-container-environment': 'Development',
      'com.apple.application-identifier': 'TEAM123456.tech.example.app',
      'com.apple.developer.team-identifier': 'TEAM123456',
    },
  )
  assertEquals(
    resolvedEntitlements(
      { ...target, platform: 'macOS' },
      'store',
      'TEAM123456',
    ),
    {
      'com.apple.developer.icloud-services': ['CloudKit'],
      'aps-environment': 'production',
      'com.apple.application-identifier': 'TEAM123456.tech.example.app',
      'com.apple.developer.team-identifier': 'TEAM123456',
      'com.apple.developer.icloud-container-environment': 'Production',
    },
  )
  assertEquals(
    resolvedEntitlements(
      {
        ...target,
        platform: 'macOS',
        bundleID: 'tech.lakeridge.previews.example',
        entitlements: {},
      },
      'dev',
      'TEAM123456',
    ),
    {},
  )
  assertEquals(
    resolvedEntitlements(
      {
        ...target,
        platform: 'tvOS',
        bundleID: 'tech.lakeridge.previews.example',
      },
      'dev',
      'TEAM123456',
    )['get-task-allow'],
    undefined,
  )
})

Deno.test('app entitlements reject the retired plist path spelling', () => {
  const app = {
    name: 'Example',
    targets: [{ entitlements: 'Example.entitlements' }],
  } as unknown as AppManifest
  assertThrows(
    () => validateAppEntitlements(app, 'app.yml'),
    'must be a common/dev/release mapping',
  )
})

for (const overlay of ['common', 'dev', 'release'] as const) {
  for (
    const key of [
      'application-identifier',
      'com.apple.application-identifier',
      'com.apple.developer.team-identifier',
      'get-task-allow',
    ] as const
  ) {
    Deno.test(`app entitlements reject generated ${key} in ${overlay}`, () => {
      const app = {
        name: 'Example',
        targets: [{
          name: 'ExampleiOS',
          entitlements: { [overlay]: { [key]: true } },
        }],
      } as unknown as AppManifest
      assertThrows(
        () => validateAppEntitlements(app, 'app.yml'),
        `${key} is generated and must not be authored`,
      )
    })
  }
}

Deno.test('package BUILD combination has one package declaration and release manifest', () => {
  const build = combineBuildBazel(
    [
      'load("//a:a.bzl", "a")\npackage(default_visibility = ["//visibility:public"])\na(name = "a")\n',
      'load("//b:b.bzl", "b")\npackage(default_visibility = ["//visibility:public"])\nb(name = "b")\n',
    ],
    ['Apps/example/app.yml'],
  )
  assertEquals(build.match(/package\(/g)?.length, 1)
  assertIncludes(build, 'name = "release_manifest"')
  assertIncludes(build, '"Apps/example/app.yml"')
})

Deno.test('app-shell library copts thread extra rule symbols and load them', () => {
  const manifest: AppManifest = {
    name: 'Example',
    viewPilot: false,
    libraries: [
      {
        name: 'GatedLibrary',
        sources: 'Sources',
        copts: ['WUHU_UI_CONTROL_COPTS'],
        dependencies: ['//packages/view-pilot:ViewPilot'],
      },
      {
        name: 'PlainLibrary',
        sources: 'Sources',
        dependencies: ['//packages/wuhu-app:App'],
      },
    ],
    targets: [
      {
        name: 'ExampleApp',
        platform: 'macOS',
        bundleID: 'ms.liu.example',
        bundleName: 'Example',
        entitlements: {},
        families: ['mac'],
        appIcons: [],
        infoPlist: 'Sources/BazelInfo.plist',
        minimumOSVersion: '26.0',
        info: {},
        dependencies: [':GatedLibrary'],
        frameworks: ['@example//:DynamicFramework'],
      },
      {
        name: 'ExampleAppIOS',
        platform: 'iOS',
        bundleID: 'ms.liu.example.ios',
        bundleName: 'Example',
        entitlements: {},
        families: ['iphone'],
        appIcons: [],
        infoPlist: 'Sources/BazelInfo-iOS.plist',
        minimumOSVersion: '26.0',
        info: {},
        dependencies: [':PlainLibrary'],
      },
    ],
  }

  const build = generateAppBuildBazel(manifest)

  // The extra copts symbol is loaded from rules.bzl alongside the base symbol.
  assertIncludes(
    build,
    `load("//bazel/rules:rules.bzl", "WUHU_SWIFT_LANGUAGE_MODE_COPTS", "WUHU_UI_CONTROL_COPTS", "wuhu_platforms")`,
  )
  // The gated library appends the extra symbol; the plain one does not.
  assertIncludes(
    build,
    'copts = WUHU_SWIFT_LANGUAGE_MODE_COPTS + WUHU_UI_CONTROL_COPTS,',
  )
  assertIncludes(build, 'copts = WUHU_SWIFT_LANGUAGE_MODE_COPTS,')
  assertIncludes(
    build,
    'frameworks = [\n        "@example//:DynamicFramework",\n    ],',
  )
  // Each shell library is constrained to the lanes of the app targets that
  // actually depend on it, not to the union across the whole shell: that is what
  // lets a macOS-only library sit beside a mobile one in the same app.yml.
  assertIncludes(
    build,
    'target_compatible_with = wuhu_platforms([\n        "mac",\n    ]),',
  )
  assertIncludes(
    build,
    'target_compatible_with = wuhu_platforms([\n        "ios",\n    ]),',
  )
})

Deno.test('app target resource files and directories become a rules_apple glob', () => {
  const manifest: AppManifest = {
    name: 'Example',
    targets: [
      {
        name: 'ExampleApp',
        platform: 'macOS',
        bundleID: 'ms.liu.example',
        bundleName: 'Example',
        entitlements: {},
        families: ['mac'],
        appIcons: [],
        resources: [
          'Resources/LaunchScreen.storyboard',
          'Resources/Localizations',
        ],
        infoPlist: 'Sources/BazelInfo.plist',
        minimumOSVersion: '26.0',
        info: {},
        dependencies: [],
      },
    ],
  }

  assertIncludes(
    generateAppBuildBazel(manifest),
    'resources = glob([\n        "Resources/LaunchScreen.storyboard",\n        "Resources/LaunchScreen.storyboard/**",\n        "Resources/Localizations",\n        "Resources/Localizations/**",\n    ], allow_empty = True),',
  )
})

Deno.test('app bundle plists derive boilerplate and preserve real capabilities', () => {
  const target: AppManifest['targets'][number] = {
    name: 'ExampleApp',
    platform: 'iOS',
    bundleID: 'tech.example.app',
    bundleName: 'Example',
    displayName: 'Example App',
    entitlements: {},
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Info.plist',
    minimumOSVersion: '18.0',
    dependencies: [],
    info: { UIRequiredDeviceCapabilities: ['arkit'] },
  }
  const app: AppManifest = {
    name: 'Example',
    marketingVersion: '2.3.4',
    developmentRegion: 'zh-Hans',
    usesNonExemptEncryption: false,
    targets: [target],
  }

  assertEquals(appBundleInfo(app, target, 'application'), {
    CFBundleDevelopmentRegion: 'zh-Hans',
    CFBundleDisplayName: 'Example App',
    CFBundleIdentifier: 'tech.example.app',
    CFBundleInfoDictionaryVersion: '6.0',
    CFBundleName: 'Example',
    CFBundlePackageType: 'APPL',
    CFBundleShortVersionString: '2.3.4',
    CFBundleVersion: '1',
    ITSAppUsesNonExemptEncryption: false,
    UILaunchScreen: {},
    UIRequiredDeviceCapabilities: ['arm64', 'arkit'],
  })

  const extension = { ...target, info: {} }
  const extensionInfo = appBundleInfo(app, extension, 'extension')
  assertEquals(extensionInfo.CFBundlePackageType, 'XPC!')
  assertEquals(extensionInfo.UIRequiredDeviceCapabilities, ['arm64'])
  assertEquals(extensionInfo.UILaunchScreen, undefined)

  const mac = { ...target, platform: 'macOS' as const, info: {} }
  const macInfo = appBundleInfo(app, mac, 'application')
  assertEquals(macInfo.NSMainStoryboardFile, '')
  assertEquals(macInfo.UIRequiredDeviceCapabilities, undefined)
})

Deno.test('Watch application plists receive complete application metadata', () => {
  const watch: NonNullable<AppManifest['watchApplications']>[number] = {
    name: 'ExampleWatch',
    platform: 'watchOS',
    bundleID: 'tech.example.app.watchkitapp',
    bundleName: 'Example',
    entitlements: {},
    families: ['watch'],
    appIcons: [],
    infoPlist: 'Watch/Info.plist',
    minimumOSVersion: '11.0',
    dependencies: [],
    info: {
      WKApplication: true,
      WKCompanionAppBundleIdentifier: 'tech.example.app',
    },
  }
  const app: AppManifest = {
    name: 'Example',
    marketingVersion: '2.3.4',
    usesNonExemptEncryption: false,
    watchApplications: [watch],
    targets: [],
  }

  populateAppBundleInfo(app)

  assertEquals(watch.info, {
    CFBundleDevelopmentRegion: 'en',
    CFBundleDisplayName: 'Example',
    CFBundleIdentifier: 'tech.example.app.watchkitapp',
    CFBundleInfoDictionaryVersion: '6.0',
    CFBundleName: 'Example',
    CFBundlePackageType: 'APPL',
    CFBundleShortVersionString: '2.3.4',
    CFBundleVersion: '1',
    ITSAppUsesNonExemptEncryption: false,
    WKApplication: true,
    WKCompanionAppBundleIdentifier: 'tech.example.app',
  })
  assertThrows(
    () =>
      appBundleInfo(app, {
        ...watch,
        info: { UIRequiredDeviceCapabilities: ['arm64'] },
      }, 'application'),
    'UIRequiredDeviceCapabilities is forbidden on watchOS',
  )
})

Deno.test('app bundle plist boilerplate has one typed source of truth', () => {
  const target: AppManifest['targets'][number] = {
    name: 'ExampleApp',
    platform: 'iOS',
    bundleID: 'tech.example.app',
    bundleName: 'Example',
    entitlements: {},
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Info.plist',
    minimumOSVersion: '18.0',
    dependencies: [],
    info: { CFBundleIdentifier: 'duplicated' },
  }
  assertThrows(
    () =>
      appBundleInfo(
        { name: 'Example', targets: [target] },
        target,
        'application',
      ),
    'info.CFBundleIdentifier is generated from typed app.yml fields',
  )
})

Deno.test('app extensions compile and embed from declarative shell metadata', () => {
  const manifest: AppManifest = {
    name: 'Example',
    libraries: [
      {
        name: 'WidgetLibrary',
        sources: 'Widgets/Sources',
      },
    ],
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
    targets: [
      {
        name: 'ExampleApp',
        platform: 'iOS',
        bundleID: 'tech.example.app',
        bundleName: 'Example',
        entitlements: {},
        families: ['iphone', 'ipad'],
        appIcons: [],
        infoPlist: 'Sources/BazelInfo.plist',
        minimumOSVersion: '18.0',
        dependencies: [],
        extensions: ['ExampleWidgets'],
        info: {},
      },
    ],
  }

  const build = generateAppBuildBazel(manifest)
  assertIncludes(
    build,
    'load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_extension")',
  )
  assertIncludes(build, 'ios_extension(\n    name = "ExampleWidgets",')
  assertIncludes(
    build,
    'resources = glob([\n        "Widgets/Resources",\n        "Widgets/Resources/**",\n    ], allow_empty = True),',
  )
  assertIncludes(build, 'extensions = [\n        ":ExampleWidgets",\n    ],')
})

Deno.test('watch applications compile and embed from declarative companion metadata', () => {
  const watch = {
    name: 'ExampleWatch',
    platform: 'watchOS' as const,
    bundleID: 'tech.example.app.watchkitapp',
    bundleName: 'Example',
    entitlements: {},
    families: ['watch'],
    appIcons: ['Watch/Assets.xcassets/AppIcon.appiconset/**'],
    infoPlist: 'Watch/Info.plist',
    minimumOSVersion: '11.0',
    dependencies: [':WatchLibrary'],
    info: { WKCompanionAppBundleIdentifier: 'tech.example.app' },
  }
  const manifest: AppManifest = {
    name: 'Example',
    signingTeamID: 'TEAM123456',
    libraries: [{ name: 'WatchLibrary', sources: 'Watch/Sources' }],
    watchApplications: [watch],
    targets: [{
      ...watch,
      name: 'ExampleApp',
      platform: 'iOS',
      bundleID: 'tech.example.app',
      families: ['iphone'],
      appIcons: [],
      infoPlist: 'Sources/Info.plist',
      minimumOSVersion: '18.0',
      dependencies: [],
      info: {},
      watchApplication: watch.name,
    }],
  }

  validateAppExtensions(manifest, 'app.yml')
  const build = generateAppBuildBazel(manifest)
  assertIncludes(
    build,
    'load("@build_bazel_rules_apple//apple:watchos.bzl", "watchos_application")',
  )
  assertIncludes(build, 'watchos_application(\n    name = "ExampleWatch",')
  assertIncludes(
    build,
    'profile_name = "Wuhu Store tech.example.app.watchkitapp watchOS"',
  )
  assertIncludes(build, 'watch_application = ":ExampleWatch",')
  assertIncludes(
    build,
    'target_compatible_with = wuhu_platforms([\n        "watchos",',
  )
})

Deno.test('declared app intents reach the bundle and its library', () => {
  const manifest: AppManifest = {
    name: 'Example',
    libraries: [
      { name: 'AppLibrary', sources: 'Sources' },
      { name: 'OtherLibrary', sources: 'Other' },
    ],
    extensions: [{
      name: 'ExampleExtension',
      platform: 'iOS',
      bundleID: 'tech.example.app.ext',
      bundleName: 'Extension',
      entitlements: {},
      families: ['iphone'],
      appIcons: [],
      infoPlist: 'Other/Info.plist',
      minimumOSVersion: '18.0',
      dependencies: [':OtherLibrary'],
      info: {},
    }],
    targets: [{
      name: 'ExampleApp',
      platform: 'iOS',
      bundleID: 'tech.example.app',
      bundleName: 'Example',
      entitlements: {},
      families: ['iphone'],
      appIcons: [],
      infoPlist: 'Sources/Info.plist',
      minimumOSVersion: '18.0',
      dependencies: [':AppLibrary'],
      appIntents: [':AppLibrary'],
      extensions: ['ExampleExtension'],
      info: {},
    }],
  }

  validateAppIntents(manifest, 'app.yml')
  const build = generateAppBuildBazel(manifest)
  assertIncludes(build, '    app_intents = [\n        ":AppLibrary",\n    ],')
  assertIncludes(
    build,
    'swift_library(\n    name = "AppLibrary",',
  )
  assertIncludes(
    build,
    '    linkopts = [\n        "-framework",\n        "AppIntents",\n    ],',
  )
  // Only the library that publishes intents earns the link flag.
  assertEquals(
    build.split('linkopts = [').length - 1,
    1,
  )
})

Deno.test('app intents must name a declared library this bundle links', () => {
  const target: AppManifest['targets'][number] = {
    name: 'ExampleApp',
    platform: 'iOS',
    bundleID: 'tech.example.app',
    bundleName: 'Example',
    entitlements: {},
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Sources/Info.plist',
    minimumOSVersion: '18.0',
    dependencies: [':AppLibrary'],
    appIntents: ['//packages/other:Thing'],
    info: {},
  }
  assertThrows(
    () =>
      validateAppIntents({
        name: 'Example',
        libraries: [{ name: 'AppLibrary', sources: 'Sources' }],
        targets: [target],
      }, 'app.yml'),
    'not a library this shell declares',
  )
  assertThrows(
    () =>
      validateAppIntents({
        name: 'Example',
        libraries: [{ name: 'AppLibrary', sources: 'Sources' }],
        targets: [{ ...target, dependencies: [], appIntents: [':AppLibrary'] }],
      }, 'app.yml'),
    'without depending on it',
  )
})

Deno.test('watch applications require one iOS companion', () => {
  const watch = {
    name: 'ExampleWatch',
    platform: 'watchOS' as const,
    bundleID: 'tech.example.app.watchkitapp',
    bundleName: 'Example',
    entitlements: {},
    families: ['watch'],
    appIcons: [],
    infoPlist: 'Watch/Info.plist',
    minimumOSVersion: '11.0',
    dependencies: [],
    info: {},
  }
  assertThrows(
    () =>
      validateAppExtensions({
        name: 'Example',
        watchApplications: [watch],
        targets: [],
      }, 'app.yml'),
    'must have exactly one iOS companion',
  )
})

Deno.test('app extension embedding names an existing same-platform bundle', () => {
  const target = {
    name: 'ExampleApp',
    platform: 'iOS' as const,
    bundleID: 'tech.example.app',
    bundleName: 'Example',
    entitlements: {},
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Info.plist',
    minimumOSVersion: '18.0',
    dependencies: [],
    extensions: ['ExampleWidgets'],
    info: {},
  }
  assertThrows(
    () =>
      validateAppExtensions({ name: 'Example', targets: [target] }, 'app.yml'),
    'does not declare as an extension',
  )
  assertThrows(
    () =>
      validateAppExtensions(
        {
          name: 'Example',
          targets: [target],
          extensions: [
            {
              name: 'ExampleWidgets',
              platform: 'macOS',
              bundleID: target.bundleID,
              bundleName: target.bundleName,
              entitlements: target.entitlements,
              families: target.families,
              appIcons: target.appIcons,
              infoPlist: target.infoPlist,
              minimumOSVersion: target.minimumOSVersion,
              dependencies: target.dependencies,
              info: target.info,
            },
          ],
        },
        'app.yml',
      ),
    'cannot embed ExampleWidgets (macOS)',
  )
})

Deno.test('an app shell exports its manifest as a label', () => {
  assertIncludes(
    generateAppBuildBazel({ name: 'Example', targets: [] }),
    'exports_files(["app.yml"])',
  )
})

Deno.test('release blocks are validated at parse', () => {
  assertThrows(
    () =>
      validateTargetRelease({
        name: 'wuhu',
        kind: 'executable',
        sources: 'Sources',
        release: { teamID: '97w7a3y9gd' },
        manifestDir: 'packages/wuhu-core/Targets/wuhu',
      }),
    'release.teamID must be 10 characters of A-Z0-9',
  )
  assertThrows(
    () =>
      validateTargetRelease({
        name: 'CLIKit',
        kind: 'library',
        sources: 'Sources',
        release: { teamID: '97W7A3Y9GD' },
        manifestDir: 'packages/wuhu-core/Targets/CLIKit',
      }),
    'is a library, not an executable',
  )
  assertThrows(
    () =>
      validateAppRelease(
        {
          name: 'Example',
          release: { name: 'Example App', platforms: ['mac'] },
          targets: [],
        },
        'packages/example/Apps/example',
      ),
    'release.name must be kebab-case',
  )
  assertThrows(
    () =>
      validateAppRelease(
        {
          name: 'Example',
          release: { name: 'example', platforms: [] },
          targets: [],
        },
        'packages/example/Apps/example',
      ),
    'release.platforms must list at least one',
  )
})

Deno.test('an app-shell library no app target depends on is rejected', () => {
  const manifest: AppManifest = {
    name: 'Orphan',
    libraries: [{ name: 'OrphanLibrary', sources: 'Sources' }],
    targets: [],
  }
  let message = ''
  try {
    generateAppBuildBazel(manifest)
  } catch (error) {
    message = (error as Error).message
  }
  assertEquals(
    message,
    'Orphan app.yml: library OrphanLibrary is not reachable from any app target',
  )
})

// The SwiftPM identity is the lowercased last URL segment with `.git` stripped;
// it is the value `.product(package:)` references and the one Package.resolved
// records. These mirror the transforms rules_swift_package_manager relies on
// when minting `swiftpkg_*` repo names, so drifting here would silently break
// the Bazel labels emitted into BUILD.bazel and MODULE.bazel.
Deno.test('swiftPMIdentityFromUrl lowercases the last segment and strips .git', () => {
  assertEquals(
    swiftPMIdentityFromUrl('https://github.com/jpsim/Yams.git'),
    'yams',
  )
  assertEquals(
    swiftPMIdentityFromUrl('https://github.com/groue/GRDB.swift.git'),
    'grdb.swift',
  )
  assertEquals(
    swiftPMIdentityFromUrl('git@github.com:wuhu-labs/tca26.git'),
    'tca26',
  )
  assertEquals(
    swiftPMIdentityFromUrl('https://github.com/apple/swift-nio'),
    'swift-nio',
  )
})

Deno.test('bazelRepoFromUrl prefixes swiftpkg_ and maps - to _', () => {
  assertEquals(
    bazelRepoFromUrl('https://github.com/apple/swift-identified-collections'),
    'swiftpkg_swift_identified_collections',
  )
  assertEquals(
    bazelRepoFromUrl('https://github.com/jpsim/Yams.git'),
    'swiftpkg_yams',
  )
  assertEquals(
    bazelRepoFromUrl('https://github.com/groue/GRDB.swift.git'),
    'swiftpkg_grdb.swift',
  )
})

Deno.test('bazelPackageFromPath resolves a sibling path to //packages/<dir>', () => {
  assertEquals(
    bazelPackageFromPath('packages/wuhu-ai', '../wuhu-json'),
    '//packages/wuhu-json',
  )
  assertEquals(
    bazelPackageFromPath('packages/wuhu-app', '../wuhu-core'),
    '//packages/wuhu-core',
  )
})

Deno.test('productTargetLabel maps a list product to itself and honors a map override', () => {
  const listOnly: ExternalPackage = { products: ['Fetch', 'FetchSSE'] }
  assertEquals(productTargetLabel(listOnly, 'Fetch'), 'Fetch')
  assertEquals(productTargetLabel(listOnly, 'FetchSSE'), 'FetchSSE')

  const override: ExternalPackage = {
    products: { 'Product': 'AliasedTarget' },
  }
  assertEquals(productTargetLabel(override, 'Product'), 'AliasedTarget')
})

const basePkg: PackageManifest = {
  name: 'P',
  owner: 'shared',
  swiftToolsVersion: '6.3',
  packageName: 'PKit',
  checks: { build: ['linux', 'mac'], test: ['linux', 'mac'] },
}

function minimalTarget(name: string, kind: TargetKind): TargetManifest {
  return { name, kind, sources: 'Sources', manifestDir: `Targets/${name}` }
}

// A macro sibling applies as a compiler plugin on a library/binary (plugins=),
// but a test that imports the macro module for assertMacroExpansion needs it in
// deps=; a non-macro sibling always lands in deps=.
Deno.test('partitionBazelDeps splits a macro sibling by consumer kind', () => {
  const targetNames = new Set(['Lib', 'Mac'])
  const kindByName = new Map<string, TargetKind>([
    ['Lib', 'library'],
    ['Mac', 'macro'],
  ])

  assertEquals(
    partitionBazelDeps(basePkg, targetNames, kindByName, ['Mac']),
    { deps: [], plugins: [`":Mac"`] },
  )
  assertEquals(
    partitionBazelDeps(basePkg, targetNames, kindByName, ['Mac'], true),
    { deps: [`":Mac"`], plugins: [] },
  )
  assertEquals(
    partitionBazelDeps(basePkg, targetNames, kindByName, ['Lib']),
    { deps: [`":Lib"`], plugins: [] },
  )
})

const avcodecLowering = {
  binaryTarget: {
    url: 'https://example.com/libavcodec.zip',
    checksum: 'abc123',
  },
}

const quickjsLowering = {
  cTarget: {
    module: 'CQuickJS',
    fetch: {
      url: 'https://example.com/quickjs.tar.gz',
      sha256: 'def456',
      stripPrefix: 'quickjs-0.15.1',
    },
    sources: ['dtoa.c', 'quickjs.c'],
    publicHeader: 'quickjs.h',
    defines: ['_GNU_SOURCE'],
    unsafeFlags: ['-funsigned-char'],
    linuxLibraries: ['m', 'dl'],
  },
}

Deno.test('upstream C headers already under include stay in place', () => {
  assertEquals(requiresPublicHeaderMaterialization('quickjs.h'), true)
  assertEquals(
    requiresPublicHeaderMaterialization('include/smb2/libsmb2.h'),
    false,
  )
})

// A raw Bazel label names a repository the SwiftPM graph cannot see (a pinned
// http_archive): it passes through verbatim on the Bazel side, and it must
// carry a swiftpm: lowering so the SwiftPM side has a real target for it.
Deno.test('partitionBazelDeps passes a lowered raw Bazel label through verbatim', () => {
  const targetNames = new Set(['Lib'])
  const kindByName = new Map<string, TargetKind>([['Lib', 'library']])

  assertEquals(
    partitionBazelDeps(basePkg, targetNames, kindByName, [
      { name: '@ffmpeg//:libavcodec', swiftpm: avcodecLowering },
      { name: '//packages/other:Thing', swiftpm: avcodecLowering },
    ]),
    {
      deps: [`"@ffmpeg//:libavcodec"`, `"//packages/other:Thing"`],
      plugins: [],
    },
  )
  assertThrows(
    () => partitionBazelDeps(basePkg, targetNames, kindByName, ['Nope']),
    'No external package declares product Nope',
  )
})

Deno.test('a raw Bazel label without a swiftpm lowering is rejected on every path', () => {
  const targetNames = new Set(['Lib'])
  const kindByName = new Map<string, TargetKind>([['Lib', 'library']])
  assertThrows(
    () =>
      partitionBazelDeps(basePkg, targetNames, kindByName, [
        '@ffmpeg//:libavcodec',
      ]),
    'declares no swiftpm: lowering',
  )
  assertThrows(
    () => rawLabelLowering({ name: '@quickjs//:quickjs' }),
    'declares no swiftpm: lowering',
  )
  assertThrows(
    () =>
      rawLabelLowering({
        name: '@quickjs//:quickjs',
        swiftpm: { ...avcodecLowering, ...quickjsLowering },
      }),
    'exactly one of swiftpm.binaryTarget, cTarget or systemLibrary',
  )
})

Deno.test('the retired swift: toggle is rejected with a pointer to swiftpm lowerings', () => {
  const targetNames = new Set(['Lib'])
  const kindByName = new Map<string, TargetKind>([['Lib', 'library']])
  assertThrows(
    () =>
      partitionBazelDeps(basePkg, targetNames, kindByName, [
        { name: '@ffmpeg//:libavcodec', swift: false } as unknown as {
          name: string
        },
      ]),
    'retired `swift:` toggle',
  )
})

Deno.test('generatePackageSwift lowers raw labels to binaryTarget and local cTarget decls', () => {
  const target: TargetManifest = {
    ...minimalTarget('Lib', 'library'),
    dependencies: [
      { name: '@ffmpeg//:libavcodec', swiftpm: avcodecLowering },
      { name: '@quickjs//:quickjs', swiftpm: quickjsLowering },
    ],
  }
  const swift = generatePackageSwift(
    { ...basePkg, products: ['Lib'] },
    'packages/p',
    [target],
  )
  assertIncludes(
    swift,
    `dependencies: [\n        "libavcodec",\n        "CQuickJS",\n      ]`,
  )
  assertIncludes(
    swift,
    `.binaryTarget(\n      name: "libavcodec",\n      url: "https://example.com/libavcodec.zip",\n      checksum: "abc123"\n    )`,
  )
  assertIncludes(swift, `.target(\n      name: "CQuickJS"`)
  assertIncludes(swift, `path: ".upstream/CQuickJS"`)
  assertIncludes(swift, `sources: ["dtoa.c", "quickjs.c"]`)
  assertIncludes(swift, `publicHeadersPath: "include"`)
  assertIncludes(swift, `.define("_GNU_SOURCE")`)
  assertIncludes(swift, `.unsafeFlags(["-funsigned-char"])`)
  assertIncludes(
    swift,
    `.linkedLibrary("m", .when(platforms: [.linux]))`,
  )
})

Deno.test('collectLoweredDependencies dedupes identical lowerings and rejects conflicts', () => {
  const first: TargetManifest = {
    ...minimalTarget('A', 'library'),
    dependencies: [{ name: '@ffmpeg//:libavcodec', swiftpm: avcodecLowering }],
  }
  const second: TargetManifest = {
    ...minimalTarget('B', 'library'),
    dependencies: [{ name: '@ffmpeg//:libavcodec', swiftpm: avcodecLowering }],
  }
  assertEquals(
    [...collectLoweredDependencies([first, second]).keys()],
    ['libavcodec'],
  )
  const conflicting: TargetManifest = {
    ...minimalTarget('C', 'library'),
    dependencies: [{
      name: '@ffmpeg//:libavcodec',
      swiftpm: {
        binaryTarget: { url: 'https://example.com/other.zip', checksum: 'x' },
      },
    }],
  }
  assertThrows(
    () => collectLoweredDependencies([first, conflicting]),
    'conflicting swiftpm lowerings for libavcodec',
  )
})

Deno.test('bazelIgnore enumerates deno node_modules and per-package SwiftPM litter', () => {
  assertEquals(
    bazelIgnore(['packages/wuhu-web'], ['packages/arcroom']),
    'packages/arcroom/.build\npackages/arcroom/.upstream\npackages/arcroom/Packages\npackages/wuhu-web/node_modules\n',
  )
})

Deno.test('assertNoMacroProductExport rejects a macro consumed as an external product', () => {
  const macroNames = new Set(['ContractMacros'])
  assertThrows(
    () =>
      assertNoMacroProductExport(
        { path: '../producer', products: ['ContractMacros'] },
        macroNames,
        'packages/consumer/package.yml',
      ),
    'macro targets are consumed within their owning package',
  )
  // The map form resolves through the target label, catching an aliased product.
  assertThrows(
    () =>
      assertNoMacroProductExport(
        { path: '../producer', products: { 'Alias': 'ContractMacros' } },
        macroNames,
        'loc',
      ),
    'macro targets are consumed within their owning package',
  )
  // A non-macro product is accepted.
  assertNoMacroProductExport(
    { path: '../producer', products: ['LoopCore'] },
    macroNames,
    'loc',
  )
})

Deno.test('productTargets rejects an explicit macro product and drops macros otherwise', () => {
  const targets = [
    minimalTarget('Lib', 'library'),
    minimalTarget('Mac', 'macro'),
  ]
  assertThrows(
    () => productTargets({ ...basePkg, products: ['Mac'] }, targets),
    'is a macro target',
  )
  assertEquals(
    productTargets({ ...basePkg, products: ['Lib'] }, targets).map((t) =>
      t.name
    ),
    ['Lib'],
  )
  assertEquals(
    productTargets({ ...basePkg }, targets).map((t) => t.name),
    ['Lib'],
  )
  assertEquals(
    productTargets({ ...basePkg, products: 'all' }, targets).map((t) => t.name),
    ['Lib'],
  )
})

Deno.test('generatePackageSwift imports CompilerPluginSupport only with a macro target', () => {
  const withMacro = generatePackageSwift(
    { ...basePkg, products: 'all' },
    'packages/p',
    [minimalTarget('Mac', 'macro')],
  )
  assertIncludes(withMacro, 'import CompilerPluginSupport')
  assertIncludes(withMacro, `.macro(\n      name: "Mac"`)

  const withoutMacro = generatePackageSwift(
    { ...basePkg, products: 'all' },
    'packages/p',
    [minimalTarget('Lib', 'library')],
  )
  if (withoutMacro.includes('CompilerPluginSupport')) {
    throw new Error(
      'did not expect a CompilerPluginSupport import without a macro target',
    )
  }
})

Deno.test('an executable may expose a product name without changing its target module', async () => {
  const target: TargetManifest = {
    ...minimalTarget('CLIV2', 'executable'),
    productName: 'arcroom-cli',
  }
  const swift = generatePackageSwift(
    { ...basePkg, products: ['CLIV2'] },
    'packages/p',
    [target],
  )
  assertIncludes(
    swift,
    '.executable(name: "arcroom-cli", targets: ["CLIV2"])',
  )
  const bazel = await generateBuildBazel(basePkg, [target])
  assertIncludes(bazel, 'name = "CLIV2"')
  assertIncludes(
    bazel,
    'alias(\n    name = "arcroom-cli",\n    actual = ":CLIV2",\n)',
  )
})

Deno.test('generateBuildBazel discovers DocC catalogs and emits a merged site', async () => {
  const root = await Deno.makeTempDir()
  try {
    const targets = [
      {
        ...minimalTarget('Base', 'library'),
        manifestDir: join(root, 'Targets/Base'),
      },
      {
        ...minimalTarget('Feature', 'library'),
        dependencies: ['Base'],
        manifestDir: join(root, 'Targets/Feature'),
      },
    ]
    for (const target of targets) {
      const catalog = join(
        target.manifestDir,
        'Sources',
        `${target.name}.docc`,
      )
      await Deno.mkdir(catalog, { recursive: true })
      await Deno.writeTextFile(join(catalog, 'index.md'), '# Documentation')
    }

    const build = await generateBuildBazel(basePkg, targets)
    assertIncludes(build, '"wuhu_docc_archive"')
    assertIncludes(build, '"wuhu_docc_site"')
    assertIncludes(build, 'name = "BaseDocC"')
    assertIncludes(build, 'name = "FeatureDocC"')
    assertIncludes(build, 'dependencies = [\n        ":BaseDocC",\n    ]')
    assertIncludes(build, 'name = "docs"')
    assertEquals(build.match(/tags = \["manual"\]/g)?.length, 3)
    assertIncludes(
      build,
      'archives = [\n        ":BaseDocC",\n        ":FeatureDocC",\n    ]',
    )
    assertIncludes(
      build,
      'catalog = glob(["Targets/Feature/Sources/Feature.docc/**"])',
    )
  } finally {
    await Deno.remove(root, { recursive: true })
  }
})

Deno.test('generateBuildBazel stamps an executable with a status genrule and define', async () => {
  const build = await generateBuildBazel(basePkg, [
    { ...minimalTarget('wuhu', 'executable'), stamp: true },
  ])
  assertIncludes(build, `name = "wuhu_stamp"`)
  assertIncludes(build, 'stamp = 1')
  // The cmd body crosses four quoting layers (TS -> Starlark -> genrule Make
  // expansion -> bash heredoc); pin the literals whose $ count is load-bearing.
  assertIncludes(
    build,
    "version=$$(sed -n 's/^STABLE_WUHU_VERSION //p' bazel-out/stable-status.txt)",
  )
  assertIncludes(
    build,
    "date=$$(sed -n 's/^WUHU_BUILD_DATE //p' bazel-out/volatile-status.txt)",
  )
  assertIncludes(build, 'cat > $@ <<SWIFT')
  assertIncludes(build, `static let version = "$\${version:?}"`)
  assertIncludes(
    build,
    `srcs = glob(["Targets/wuhu/Sources/**/*.swift"]) + [":wuhu_stamp"]`,
  )
  assertIncludes(build, `"-DWUHU_STAMPED"`)

  const plain = await generateBuildBazel(basePkg, [
    minimalTarget('tool', 'executable'),
  ])
  if (plain.includes('stamp')) {
    throw new Error('did not expect stamp rules on an unstamped executable')
  }
})

Deno.test('generateBuildBazel embeds an executable Info.plist on macOS only', async () => {
  const build = await generateBuildBazel(basePkg, [
    {
      ...minimalTarget('wuhu', 'executable'),
      stamp: true,
      info: { CFBundleIdentifier: 'ai.wuhu.cli', Cost: '$5 \\ R&D' },
    },
  ])
  assertIncludes(build, `name = "wuhu_info_plist"`)
  assertIncludes(build, 'outs = ["Targets/wuhu/Info.plist"]')
  assertIncludes(
    build,
    `sed "s/@WUHU_VERSION@/$\${version:?}/g" > $@ <<'PLIST'`,
  )
  assertIncludes(
    build,
    '\t<key>CFBundleIdentifier</key>\n\t<string>ai.wuhu.cli</string>',
  )
  // Starlark unescapes `\\` and Make expansion unescapes `$$`; the quoted
  // heredoc passes the rest through.
  assertIncludes(build, '<string>$$5 \\\\ R&amp;D</string>')
  assertIncludes(
    build,
    '\t<key>CFBundleShortVersionString</key>\n\t<string>@WUHU_VERSION@</string>\n\t<key>CFBundleVersion</key>\n\t<string>@WUHU_VERSION@</string>',
  )
  assertIncludes(build, 'target_compatible_with = wuhu_platforms(["mac"])')
  assertIncludes(
    build,
    '    additional_linker_inputs = select({\n        "//bazel/constraints:mac": [":wuhu_info_plist"],\n        "//conditions:default": [],\n    }),',
  )
  assertIncludes(
    build,
    '    linkopts = select({\n        "//bazel/constraints:mac": ["-Wl,-sectcreate,__TEXT,__info_plist,$(location :wuhu_info_plist)"],\n        "//conditions:default": [],\n    }),',
  )

  const plain = await generateBuildBazel(basePkg, [
    { ...minimalTarget('tool', 'executable'), stamp: true },
  ])
  if (plain.includes('info_plist')) {
    throw new Error('did not expect an Info.plist without info:')
  }
})

Deno.test('executable info blocks are validated at parse', () => {
  const target = {
    ...minimalTarget('wuhu', 'executable'),
    stamp: true,
    info: { CFBundleIdentifier: 'ai.wuhu.cli' },
  }
  validateTargetInfo(target)
  assertThrows(
    () => validateTargetInfo({ ...target, stamp: false }),
    'is not a stamped executable',
  )
  assertThrows(
    () => validateTargetInfo({ ...target, kind: 'library' }),
    'is not a stamped executable',
  )
  assertThrows(
    () => validateTargetInfo({ ...target, info: { CFBundleName: 'wuhu' } }),
    'must declare CFBundleIdentifier',
  )
  assertThrows(
    () =>
      validateTargetInfo({
        ...target,
        info: { ...target.info, CFBundleVersion: '1' },
      }),
    'CFBundleVersion is stamped from the release version',
  )
})

Deno.test('package target copts load rule symbols once and reject literal flags', async () => {
  const build = await generateBuildBazel(basePkg, [
    {
      ...minimalTarget('First', 'library'),
      copts: ['WUHU_UI_CONTROL_COPTS'],
    },
    {
      ...minimalTarget('Second', 'library'),
      copts: ['WUHU_UI_CONTROL_COPTS'],
    },
  ])
  assertEquals(build.match(/"WUHU_UI_CONTROL_COPTS"/g)?.length, 1)
  assertEquals(build.match(/copts = WUHU_UI_CONTROL_COPTS/g)?.length, 2)

  await assertRejects(
    () =>
      generateBuildBazel(basePkg, [{
        ...minimalTarget('Invalid', 'library'),
        copts: ['-DBUILD_WITH_UI_CONTROL'],
      }]),
    'target copts entry is not a rules.bzl symbol',
  )
})

Deno.test('generateBuildBazel threads a test size into swift_test and rejects an invalid one', async () => {
  const sized = await generateBuildBazel(basePkg, [
    { ...minimalTarget('Lib', 'library'), tests: { size: 'large' } },
  ])
  assertIncludes(sized, `    size = "large",`)

  const unsized = await generateBuildBazel(basePkg, [
    { ...minimalTarget('Lib', 'library'), tests: {} },
  ])
  if (unsized.includes('size =')) {
    throw new Error('did not expect a size attribute without tests.size')
  }

  let failed = false
  try {
    await generateBuildBazel(basePkg, [
      {
        ...minimalTarget('Lib', 'library'),
        tests: { size: 'huge' as 'large' },
      },
    ])
  } catch (error) {
    failed = true
    if (
      !String(error).includes(
        `invalid test size "huge" in Targets/Lib/target.yml`,
      )
    ) {
      throw new Error(`unexpected error: ${String(error)}`)
    }
  }
  if (!failed) throw new Error('expected an invalid test size to be rejected')
})

Deno.test('multiple test targets use folder-derived names in Bazel and SwiftPM', async () => {
  const target: TargetManifest = {
    ...minimalTarget('Feature', 'library'),
    tests: {},
    additionalTestTargets: [
      { sources: 'SnapshotTests', dependencies: ['Support'] },
      { sources: 'Nested/IntegrationTests', size: 'medium' },
    ],
  }
  const support = minimalTarget('Support', 'library')

  const build = await generateBuildBazel(basePkg, [target, support])
  assertIncludes(build, `name = "FeatureTests"`)
  assertIncludes(
    build,
    `srcs = glob(["Targets/Feature/Tests/**/*.swift"])`,
  )
  assertIncludes(build, `name = "FeatureSnapshotTests"`)
  assertIncludes(
    build,
    `srcs = glob(["Targets/Feature/SnapshotTests/**/*.swift"])`,
  )
  assertIncludes(build, `name = "FeatureIntegrationTests"`)
  assertIncludes(
    build,
    `srcs = glob(["Targets/Feature/Nested/IntegrationTests/**/*.swift"])`,
  )

  const swift = generatePackageSwift(basePkg, '.', [target, support])
  assertIncludes(swift, `.testTarget(\n      name: "FeatureTests"`)
  assertIncludes(swift, `path: "Targets/Feature/Tests"`)
  assertIncludes(swift, `.testTarget(\n      name: "FeatureSnapshotTests"`)
  assertIncludes(swift, `path: "Targets/Feature/SnapshotTests"`)
  assertIncludes(swift, `.testTarget(\n      name: "FeatureIntegrationTests"`)
  assertIncludes(swift, `path: "Targets/Feature/Nested/IntegrationTests"`)
})

Deno.test('retired tests.sources and sourceless additional targets are rejected', async () => {
  await assertRejects(
    () =>
      generateBuildBazel(basePkg, [{
        ...minimalTarget('Legacy', 'library'),
        tests: { sources: 'LegacyTests' },
      } as unknown as TargetManifest]),
    'uses retired tests.sources',
  )
  await assertRejects(
    () =>
      generateBuildBazel(basePkg, [{
        ...minimalTarget('Missing', 'library'),
        additionalTestTargets: [{}],
      } as unknown as TargetManifest]),
    'additionalTestTargets entries must declare sources',
  )
})

Deno.test('generateBuildBazel inherits E2E environment into host tests', async () => {
  const build = await generateBuildBazel(basePkg, [{
    ...minimalTarget('E2E', 'library'),
    tests: { envInherit: ['EXAMPLE_TOKEN'] },
  }])
  assertIncludes(
    build,
    `    env_inherit = [\n        "EXAMPLE_TOKEN",\n    ],`,
  )
})

Deno.test('generateBuildBazel threads execution tags into host and simulator tests', async () => {
  const build = await generateBuildBazel(applePkg, [{
    ...minimalTarget('DockerIntegration', 'library'),
    tests: {
      checks: { test: ['mac', 'ios'] },
      tags: ['no-sandbox', 'no-remote-exec', 'requires-network'],
    },
  }])
  assertIncludes(
    build,
    `    tags = [\n        "no-sandbox",\n        "no-remote-exec",\n        "requires-network",\n    ],`,
  )
  assertIncludes(
    build,
    `    tags = [\n        "resources:simulators:1",\n        "no-sandbox",\n        "no-remote-exec",\n        "requires-network",\n    ],`,
  )
})

Deno.test('generateBuildBazel hosts a simulator test only on the lanes that name a host', async () => {
  const build = await generateBuildBazel(applePkg, [{
    ...minimalTarget('Hosted', 'library'),
    tests: {
      checks: { test: ['mac', 'ios'] },
      host: { ios: '//packages/preview-kit:TestHostiOS' },
    },
  }])
  assertIncludes(
    build,
    `    minimum_os_version = "18.4",\n    test_host = "//packages/preview-kit:TestHostiOS",\n`,
  )
  assertEquals(build.split('test_host = ').length, 2)
  await assertRejects(
    () =>
      generateBuildBazel(applePkg, [{
        ...minimalTarget('Stray', 'library'),
        tests: {
          checks: { test: ['ios'] },
          host: { tvos: '//packages/preview-kit:TestHostiOS' },
        },
      }]),
    'names a test host for tvos, which is not one of its simulator test lanes',
  )
})

const applePkg: PackageManifest = {
  name: 'A',
  owner: 'shared',
  swiftToolsVersion: '6.3',
  packageName: 'AKit',
  platforms: { macOS: '15.4', iOS: '18.4', tvOS: '26.0', visionOS: '26.0' },
  checks: { build: ['mac', 'ios', 'tvos', 'visionos'], test: ['mac'] },
}

Deno.test('every Swift test links IssueReporting support without changing production deps', async () => {
  const checks = { test: ['linux', 'mac', 'ios', 'tvos', 'visionos'] as const }
  const target: TargetManifest = {
    ...minimalTarget('Feature', 'library'),
    tests: { checks: { test: [...checks.test] } },
    additionalTestTargets: [{
      sources: 'ContractTests',
      checks: { test: [...checks.test] },
    }],
  }
  const build = await generateBuildBazel(applePkg, [target])
  const support =
    '"@swiftpkg_xctest_dynamic_overlay//:IssueReportingTestSupport"'
  assertEquals(build.split(support).length - 1, 8)
  const production = build.slice(0, build.indexOf('wuhu_swift_test('))
  assertEquals(production.includes(support), false)

  const swift = generatePackageSwift(applePkg, '.', [target])
  const product =
    '.product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay")'
  assertEquals(swift.split(product).length - 1, 2)
  assertIncludes(
    swift,
    '.package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", from: "1.0.0")',
  )
  assertEquals(
    swift.slice(0, swift.indexOf('.testTarget(')).includes(product),
    false,
  )
  const withoutTests = generatePackageSwift(applePkg, '.', [
    minimalTarget('Feature', 'library'),
  ])
  assertEquals(withoutTests.includes('xctest-dynamic-overlay'), false)
})

Deno.test('a simulator test lane lowers to its own bundle target beside the swift_test', async () => {
  const build = await generateBuildBazel(applePkg, [
    {
      ...minimalTarget('Lib', 'library'),
      tests: { checks: { test: ['mac', 'ios', 'tvos'] } },
    },
  ])
  assertIncludes(build, `"wuhu_sim_test"`)
  assertIncludes(
    build,
    `wuhu_swift_test(\n    name = "LibTests",\n    package_name = "AKit",`,
  )
  assertIncludes(
    build,
    `wuhu_sim_test(\n    name = "LibTests.ios",\n    lane = "ios",\n    module_name = "LibTests",\n    package_name = "AKit",\n    minimum_os_version = "18.4",`,
  )
  assertIncludes(
    build,
    `wuhu_sim_test(\n    name = "LibTests.tvos",\n    lane = "tvos",\n    module_name = "LibTests",\n    package_name = "AKit",\n    minimum_os_version = "26.0",`,
  )
  assertEquals(
    build.match(/tags = \["resources:simulators:1"\]/g)?.length,
    2,
  )
  // Each lane's runner is its own; a lane must not see another lane's bundle.
  assertIncludes(
    build,
    `    target_compatible_with = wuhu_platforms([\n        "ios",\n    ]),`,
  )
  assertIncludes(
    build,
    `    target_compatible_with = wuhu_platforms([\n        "tvos",\n    ]),`,
  )
  assertIncludes(
    build,
    `    target_compatible_with = wuhu_platforms([\n        "mac",\n    ]),`,
  )
})

Deno.test('a simulator-only test lane drops the swift_test entirely', async () => {
  const build = await generateBuildBazel(applePkg, [
    {
      ...minimalTarget('Lib', 'library'),
      tests: { checks: { test: ['ios'] } },
    },
  ])
  assertIncludes(build, `wuhu_sim_test(\n    name = "LibTests.ios",`)
  if (build.includes('wuhu_swift_test(')) {
    throw new Error('did not expect a swift_test with no runnable lane')
  }
})

Deno.test('a package with no simulator test lane loads no wuhu_sim_test', async () => {
  const build = await generateBuildBazel(applePkg, [
    { ...minimalTarget('Lib', 'library'), tests: {} },
  ])
  if (build.includes('wuhu_sim_test')) {
    throw new Error('did not expect wuhu_sim_test without a simulator lane')
  }
})

Deno.test('a simulator test lane without a platform floor is rejected', async () => {
  await assertRejects(
    () =>
      generateBuildBazel({ ...applePkg, platforms: { macOS: '15.4' } }, [
        {
          ...minimalTarget('Lib', 'library'),
          tests: { checks: { test: ['ios'] } },
        },
      ]),
    'names ios in checks.test, but the package declares no iOS platform floor',
  )
})

Deno.test('visionos in checks.test lowers to a visionos simulator bundle', async () => {
  const build = await generateBuildBazel(applePkg, [
    {
      ...minimalTarget('Lib', 'library'),
      tests: { checks: { test: ['visionos'] } },
    },
  ])
  assertIncludes(build, `name = "LibTests.visionos"`)
  assertIncludes(build, `lane = "visionos"`)
  assertIncludes(build, `minimum_os_version = "26.0"`)
})

async function assertRejects(
  body: () => Promise<unknown>,
  expected: string,
): Promise<void> {
  try {
    await body()
  } catch (error) {
    if (String(error).includes(expected)) return
    throw new Error(`unexpected error: ${String(error)}`)
  }
  throw new Error(`expected a rejection containing ${JSON.stringify(expected)}`)
}

Deno.test('systemLibrary kind emits a .systemLibrary and a wuhu_system_library', async () => {
  const systemTarget: TargetManifest = {
    ...minimalTarget('CSQLite', 'systemLibrary'),
    sources: '.',
    apt: ['libsqlite3-dev'],
    link: ['sqlite3'],
  }
  const consumer: TargetManifest = {
    ...minimalTarget('Lib', 'library'),
    dependencies: ['CSQLite'],
  }

  const swift = generatePackageSwift(
    { ...basePkg, products: ['Lib'] },
    '.',
    [systemTarget, consumer],
  )
  assertIncludes(swift, `.systemLibrary(\n      name: "CSQLite"`)
  assertIncludes(swift, `path: "Targets/CSQLite"`)
  assertIncludes(swift, `providers: [.apt(["libsqlite3-dev"])]`)
  if (swift.includes(`.library(name: "CSQLite"`)) {
    throw new Error('a system library must not be exported as a product')
  }

  const bazel = await generateBuildBazel({ ...basePkg, products: ['Lib'] }, [
    systemTarget,
    consumer,
  ])
  assertIncludes(bazel, `"wuhu_system_library"`)
  assertIncludes(bazel, `wuhu_system_library(\n    name = "CSQLite"`)
  assertIncludes(bazel, `hdrs = glob(["Targets/CSQLite/**/*.h"])`)
  assertIncludes(bazel, `module_map = "Targets/CSQLite/module.modulemap"`)
  assertIncludes(bazel, `linkopts = [\n        "-lsqlite3",\n    ]`)
  assertIncludes(bazel, `deps = [\n        ":CSQLite",`)
})

Deno.test('a library links its declared SDK frameworks in both graphs', async () => {
  const target: TargetManifest = {
    ...minimalTarget('Player', 'library'),
    linkedFrameworks: ['AVKit'],
  }
  const swift = generatePackageSwift(
    { ...basePkg, products: ['Player'] },
    '.',
    [target],
  )
  assertIncludes(
    swift,
    `linkerSettings: [\n        .linkedFramework("AVKit")\n      ]`,
  )
  const bazel = await generateBuildBazel({ ...basePkg, products: ['Player'] }, [
    target,
  ])
  assertIncludes(
    bazel,
    `linkopts = [\n        "-framework",\n        "AVKit",\n    ],`,
  )
  assertThrows(
    () =>
      validateTargetLinkedFrameworks({
        ...minimalTarget('Tool', 'executable'),
        linkedFrameworks: ['AVKit'],
      }),
    'is kind executable, not library',
  )
})

Deno.test('objcLibrary kind emits an always-linked Objective-C target', async () => {
  const target = {
    ...minimalTarget('Bootstrap', 'objcLibrary'),
    dependencies: ['Native'],
  }
  const native = minimalTarget('Native', 'library')
  const swift = generatePackageSwift(
    { ...basePkg, products: ['Bootstrap'] },
    '.',
    [target, native],
  )
  const bazel = await generateBuildBazel(
    { ...basePkg, products: ['Bootstrap'] },
    [target, native],
  )

  assertIncludes(swift, `.target(\n      name: "Bootstrap"`)
  assertIncludes(
    bazel,
    `load("@rules_cc//cc:objc_library.bzl", "objc_library")`,
  )
  assertIncludes(bazel, `objc_library(\n    name = "Bootstrap"`)
  assertIncludes(bazel, `alwayslink = True`)
  assertIncludes(bazel, `deps = [\n        ":Native",`)
})

Deno.test('generateDenoBuildBazel emits bundle and task tests from deno.json tasks', () => {
  const build = generateDenoBuildBazel('packages/wuhu-web', {
    owner: 'wuhu',
    tasks: {
      build: 'x',
      fmt: 'f',
      typecheck: 'y',
      lint: 'z',
      test: 't',
      dev: 'ignored',
    },
  })
  assertIncludes(
    build,
    `load("//bazel/rules:deno.bzl", "deno_bundle", "deno_task_test")`,
  )
  assertIncludes(build, `deno_bundle(\n    name = "bundle"`)
  assertIncludes(build, `output_dir = "build/client"`)
  assertIncludes(build, `tags = ["requires-network"]`)
  assertIncludes(build, `task = "fmt"`)
  assertIncludes(build, `task = "typecheck"`)
  assertIncludes(build, `task = "lint"`)
  assertIncludes(build, `task = "test"`)
  if (build.includes(`"dev"`)) {
    throw new Error('did not expect a target for the dev task')
  }
})

Deno.test('generateDenoBuildBazel emits exported_dir targets', () => {
  const build = generateDenoBuildBazel('packages/wuhu-web', {
    owner: 'wuhu',
    tasks: { lint: 'z' },
    exportedDirs: { 'shell-sdk': 'app/lib/shell-sdk' },
  })
  assertIncludes(
    build,
    `load("//bazel/rules:deno.bzl", "deno_task_test", "exported_dir")`,
  )
  assertIncludes(
    build,
    `exported_dir(\n    name = "shell-sdk",\n    srcs = glob(["app/lib/shell-sdk/**"], exclude = ["**/.DS_Store"]),\n    path = "app/lib/shell-sdk",\n)`,
  )
})

Deno.test('generateDenoBuildBazel injects generated inputs and excludes their paths', () => {
  const build = generateDenoBuildBazel('packages/wuhu-web', {
    owner: 'wuhu',
    generated: {
      'app/lib/contract.gen.ts': '//tools/contract-ts:space-contract',
    },
    tasks: { build: 'x', typecheck: 'y' },
  })
  assertIncludes(
    build,
    `    generated = {\n        "//tools/contract-ts:space-contract": "app/lib/contract.gen.ts",\n    },`,
  )
  assertIncludes(build, `"app/lib/contract.gen.ts",\n        ],`)
})

Deno.test('generateDenoBuildBazel requires owner', () => {
  let failed = false
  try {
    generateDenoBuildBazel('packages/p', { tasks: { build: 'x' } })
  } catch {
    failed = true
  }
  if (!failed) throw new Error('expected missing owner to be rejected')
})

Deno.test('generateDenoBuildBazel leaves a non-member package byte-identical', () => {
  const manifest = {
    owner: 'wuhu',
    tasks: { build: 'x', typecheck: 'y', lint: 'z', test: 't' },
    exportedDirs: { 'shell-sdk': 'app/lib/shell-sdk' },
  }
  const standalone = generateDenoBuildBazel('packages/standalone', manifest)
  // Every deno package exposes :srcs so a `links` edge can name it, but a
  // package that belongs to no workspace gets no cluster wiring.
  assertIncludes(standalone, 'filegroup(')
  for (
    const attr of ['workspace_root_files', 'workspace_member_srcs', 'link_srcs']
  ) {
    if (standalone.includes(attr)) {
      throw new Error(`a non-member package must not gain ${attr}`)
    }
  }
})

Deno.test('generateDenoBuildBazel wires a workspace member to the cluster', () => {
  const build = generateDenoBuildBazel(
    'packages/wuhu-web/ui',
    { owner: 'wuhu', tasks: { typecheck: 'y', lint: 'z' } },
    {
      dir: 'packages/wuhu-web',
      members: ['packages/wuhu-web/lab', 'packages/wuhu-web/ui'],
      links: [],
    },
  )
  assertEquals(
    build,
    `load("//bazel/rules:deno.bzl", "deno_task_test")
load("//bazel/rules:rules.bzl", "wuhu_platforms")

package(default_visibility = ["//visibility:public"])

filegroup(
    name = "srcs",
    srcs = glob(
        ["**"],
        exclude = [
            ".env*",
            ".react-router/**",
            "BUILD.bazel",
            "build/**",
            "node_modules/**",
            "**/.DS_Store",
        ],
    ),
)

deno_task_test(
    name = "typecheck",
    srcs = [":srcs"],
    workspace_root_files = [
        "//packages/wuhu-web:deno.json",
        "//packages/wuhu-web:deno.lock",
    ],
    workspace_member_srcs = [
        "//packages/wuhu-web/lab:srcs",
    ],
    tags = ["requires-network"],
    task = "typecheck",
    target_compatible_with = wuhu_platforms([
        "linux",
        "mac",
    ]),
)

deno_task_test(
    name = "lint",
    srcs = [":srcs"],
    workspace_root_files = [
        "//packages/wuhu-web:deno.json",
        "//packages/wuhu-web:deno.lock",
    ],
    workspace_member_srcs = [
        "//packages/wuhu-web/lab:srcs",
    ],
    tags = ["requires-network"],
    task = "lint",
    target_compatible_with = wuhu_platforms([
        "linux",
        "mac",
    ]),
)
`,
  )
})

Deno.test('generateDenoBuildBazel omits workspace_member_srcs for a lone member', () => {
  const build = generateDenoBuildBazel(
    'packages/wuhu-web/ui',
    { owner: 'wuhu', tasks: { typecheck: 'y' } },
    { dir: 'packages/wuhu-web', members: ['packages/wuhu-web/ui'], links: [] },
  )
  assertIncludes(build, `srcs = [":srcs"]`)
  assertIncludes(build, `workspace_root_files = [`)
  if (build.includes('workspace_member_srcs')) {
    throw new Error('a lone workspace member has no siblings to pull in')
  }
})

Deno.test('isRemovableLegacyPackages refuses when Packages and packages are the same directory', () => {
  const dir = { dev: 16777232, ino: 424242 }
  if (isRemovableLegacyPackages(dir, dir)) {
    throw new Error(
      'case-insensitive collision: Packages stats as packages/ itself and must never be removed',
    )
  }
  if (isRemovableLegacyPackages({ dev: 1, ino: null }, { dev: 1, ino: 2 })) {
    throw new Error('unknown inode identity must refuse removal')
  }
  if (!isRemovableLegacyPackages({ dev: 1, ino: 10 }, { dev: 1, ino: 11 })) {
    throw new Error(
      'a genuinely distinct legacy Packages/ must stay removable',
    )
  }
  if (!isRemovableLegacyPackages({ dev: 1, ino: 10 }, { dev: 2, ino: 10 })) {
    throw new Error(
      'same inode number on a different device is a distinct directory',
    )
  }
})

// The umbrella's floor must satisfy the strictest package, and two products
// shipping to different OS floors must not be forced to agree.
Deno.test('comparePlatformVersions orders numerically, not lexically', () => {
  assertEquals(comparePlatformVersions('26.0', '9.0') > 0, true)
  assertEquals(comparePlatformVersions('15.0', '26.0') < 0, true)
  assertEquals(comparePlatformVersions('18.4', '18.10') < 0, true)
  assertEquals(comparePlatformVersions('26', '26.0'), 0)
})

Deno.test('assertLockfileHonorsPins catches a stale revision pin', () => {
  const externals = new Map<string, ExternalPackage>([
    ['tca26', {
      url: 'git@github.com:wuhu-labs/tca26.git',
      revision: 'newrevision',
      products: ['ComposableArchitecture2'],
    }],
  ])
  const lockfile = JSON.stringify({
    pins: [{ identity: 'tca26', state: { revision: 'oldrevision' } }],
  })
  assertThrows(
    () => assertLockfileHonorsPins(externals, lockfile),
    'silent no-op',
  )
})

Deno.test('assertLockfileHonorsPins catches a stale exact version', () => {
  const externals = new Map<string, ExternalPackage>([
    ['swift-webpush', {
      url: 'https://github.com/mochidev/swift-webpush.git',
      exact: '0.5.0',
      products: ['WebPush'],
    }],
  ])
  const lockfile = JSON.stringify({
    pins: [{ identity: 'swift-webpush', state: { version: '0.4.2' } }],
  })
  assertThrows(
    () => assertLockfileHonorsPins(externals, lockfile),
    'silent no-op',
  )
})

Deno.test('assertLockfileHonorsPins catches a pinned package missing from the lockfile', () => {
  const externals = new Map<string, ExternalPackage>([
    ['tca26', {
      url: 'git@github.com:wuhu-labs/tca26.git',
      revision: 'somerevision',
      products: ['ComposableArchitecture2'],
    }],
  ])
  assertThrows(
    () => assertLockfileHonorsPins(externals, JSON.stringify({ pins: [] })),
    'no pin for tca26',
  )
})

Deno.test('assertLockfileHonorsPins passes matching pins and ignores range, branch, and local externals', () => {
  const externals = new Map<string, ExternalPackage>([
    ['tca26', {
      url: 'git@github.com:wuhu-labs/tca26.git',
      revision: 'matching',
      products: ['ComposableArchitecture2'],
    }],
    ['yams', {
      url: 'https://github.com/jpsim/Yams.git',
      from: '5.0.0',
      products: ['Yams'],
    }],
    ['keel', { path: '../keel', products: ['KeelActors'] }],
  ])
  const lockfile = JSON.stringify({
    pins: [
      { identity: 'tca26', state: { revision: 'matching' } },
      { identity: 'yams', state: { revision: 'abc', version: '5.4.0' } },
    ],
  })
  assertLockfileHonorsPins(externals, lockfile)
})

Deno.test('two shells loading one rule file merge into a single load', () => {
  assertEquals(
    mergeLoads([
      'load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application")',
      'load("@build_bazel_rules_apple//apple:ios.bzl", "ios_extension", "ios_application")',
      'load("//bazel/rules:rules.bzl", "wuhu_platforms")',
    ]),
    [
      'load("//bazel/rules:rules.bzl", "wuhu_platforms")',
      'load("@build_bazel_rules_apple//apple:ios.bzl", "ios_application", "ios_extension")',
    ],
  )
})

Deno.test('a real shell outside default release lanes still has release variants', () => {
  const build = generateAppBuildBazel({
    name: 'Example',
    targets: [{
      name: 'ExampleiOS',
      platform: 'iOS',
      bundleID: 'tech.example.app',
      bundleName: 'Example',
      entitlements: {},
      families: ['iphone'],
      appIcons: [],
      infoPlist: 'Sources/BazelInfo.plist',
      minimumOSVersion: '18.0',
      dependencies: [],
      info: {},
    }],
  })
  assertIncludes(build, '"ExampleiOS-dev.entitlements"')
  assertIncludes(build, '"ExampleiOS-release.entitlements"')
})

Deno.test('a package without app shells reads no signing team', async () => {
  const unreadable = () => Promise.reject(new Error('no tools/signing'))
  assertEquals(await appSigningTeamID([], unreadable), '')
  assertEquals(
    await appSigningTeamID(
      ['packages/x/Apps/x'],
      () => Promise.resolve('ABCDE12345'),
    ),
    'ABCDE12345',
  )
  await assertRejects(
    () => appSigningTeamID(['packages/x/Apps/x'], unreadable),
    'no tools/signing',
  )
})

Deno.test('only the public tree may lack view-pilot', async () => {
  const root = await Deno.makeTempDir()
  const missing = join(root, 'view-pilot')
  assertEquals(await viewPilotProducts(missing, true), [])
  await assertRejects(() => viewPilotProducts(missing, false), 'NotFound')

  const present = join(root, 'present')
  await Deno.mkdir(present)
  await Deno.writeTextFile(
    join(present, 'package.yml'),
    'owner: internal\npackageName: ViewPilot\nproducts: [ViewPilot]\n',
  )
  assertEquals(await viewPilotProducts(present, true), ['ViewPilot'])
  assertEquals(await viewPilotProducts(present, false), ['ViewPilot'])
})

Deno.test('preview schemes are generated per shell without changing real apps', () => {
  const target = (bundleID: string): AppManifest['targets'][number] => ({
    name: 'Example',
    platform: 'iOS',
    bundleID,
    bundleName: 'Example',
    entitlements: {},
    families: ['iphone'],
    appIcons: [],
    infoPlist: 'Info.plist',
    minimumOSVersion: '18.0',
    dependencies: [],
    info: {},
  })
  const preview = target('tech.lakeridge.previews.wuhu')
  const production = target('ai.wuhu.app')
  const app: AppManifest = { name: 'Example', targets: [preview, production] }
  populateAppBundleInfo(app)
  assertEquals(preview.info.CFBundleURLTypes, [{
    CFBundleURLName: preview.bundleID,
    CFBundleURLSchemes: ['wuhu-preview'],
  }])
  assertEquals(production.info.CFBundleURLTypes, undefined)
})

Deno.test('ATS rejects every arbitrary-load override, including false values', () => {
  for (
    const key of [
      'NSAllowsLocalNetworking',
      'NSAllowsArbitraryLoadsForMedia',
      'NSAllowsArbitraryLoadsInWebContent',
    ]
  ) {
    for (const enabled of [true, false]) {
      const info = {
        NSAppTransportSecurity: {
          NSAllowsArbitraryLoads: true,
          [key]: enabled,
        },
      }
      for (
        const value of [
          info,
          { targets: [{ info }] },
          { extensions: [{ devIdentity: { info } }] },
          { watchApplications: [{ info }] },
        ]
      ) {
        assertThrows(
          () => validateAppTransportSecurity(value, 'app.yml'),
          `combines NSAllowsArbitraryLoads with ${key}`,
        )
      }
    }
    validateAppTransportSecurity({
      NSAppTransportSecurity: { [key]: true },
    }, 'Info.plist')
  }
  validateAppTransportSecurity({
    NSAppTransportSecurity: { NSAllowsArbitraryLoads: true },
  }, 'Info.plist')
  validateAppTransportSecurity({}, 'Info.plist')
})

Deno.test('ATS permits local networking when arbitrary loads are disabled', () => {
  validateAppTransportSecurity({
    NSAppTransportSecurity: {
      NSAllowsArbitraryLoads: false,
      NSAllowsLocalNetworking: true,
    },
  }, 'Info.plist')
})

Deno.test('all wuhu-app shells and generated bundle variants keep ATS overrides separate', async () => {
  const packageDir =
    new URL('../../packages/wuhu-app', import.meta.url).pathname
  const appDirs = await discoverAppDirs(packageDir)
  assertEquals(appDirs.length > 0, true)
  for (const appDir of appDirs) {
    const source = join(appDir, 'app.yml')
    const app = parse(await Deno.readTextFile(source)) as AppManifest
    validateAppTransportSecurity(app, source)
    populateAppBundleInfo(app)
    for (const target of appBundles(app)) {
      for (const variant of ['dev', 'store', 'adhoc'] as const) {
        const bundle = variantBundle(target, variant)
        validateAppTransportSecurity(bundle.info, `${target.name}.${variant}`)
        validateAppTransportSecurity(pilotInfo(bundle), `${target.name}.pilot`)
        const ats = bundle.info.NSAppTransportSecurity
        if (ats !== undefined) {
          assertEquals(ats, { NSAllowsArbitraryLoads: true })
        }
      }
    }
  }
})

Deno.test('compiled C libraries and platform dependencies lower into both graphs', async () => {
  const codec: TargetManifest = {
    name: 'Codec',
    kind: 'cLibrary',
    sources: 'Sources',
    manifestDir: 'packages/demo/Targets/Codec',
    checks: { build: ['linux'], test: ['linux'] },
    dependencies: [{
      name: '@png//:png',
      swiftpm: {
        systemLibrary: {
          module: 'CPNG',
          path: 'Targets/Codec/SystemPNG',
          apt: ['libpng-dev'],
        },
      },
    }],
  }
  const consumer: TargetManifest = {
    name: 'Consumer',
    kind: 'library',
    sources: 'Sources',
    manifestDir: 'packages/demo/Targets/Consumer',
    dependencies: [{ name: 'Codec', platforms: ['linux'] }],
  }
  const swift = generatePackageSwift(basePkg, 'packages/demo', [
    codec,
    consumer,
  ])
  assertIncludes(swift, 'publicHeadersPath: "include"')
  assertIncludes(
    swift,
    '.systemLibrary(name: "CPNG", path: "Targets/Codec/SystemPNG", providers: [.apt(["libpng-dev"])])',
  )
  assertIncludes(
    swift,
    '.target(name: "Codec", condition: .when(platforms: [.linux]))',
  )
  const bazel = await generateBuildBazel(basePkg, [codec, consumer])
  assertIncludes(bazel, 'wuhu_c_library(')
  assertIncludes(
    bazel,
    'module_map = "Targets/Codec/Sources/include/module.modulemap"',
  )
  assertIncludes(bazel, '"@png//:png"')
  assertIncludes(
    bazel,
    'select({"//bazel/constraints:linux": [":Codec"], "//conditions:default": []})',
  )
  assertThrows(
    () =>
      partitionBazelDeps(basePkg, new Set(['Codec']), new Map(), [
        { name: 'Codec', platforms: [] },
      ]),
    'dependency platforms must be a nonempty list',
  )
})

Deno.test('compiler-plugin edges reject platform conditions, including test dependencies', () => {
  for (const macrosToDeps of [false, true]) {
    assertThrows(
      () =>
        partitionBazelDeps(
          basePkg,
          new Set(['Plugin']),
          new Map([['Plugin', 'macro']]),
          [
            { name: 'Plugin', platforms: ['linux'] },
          ],
          macrosToDeps,
        ),
      'compiler-plugin dependencies do not support platform conditions',
    )
  }
})

Deno.test('compiled C targets reject DocC catalogs', async () => {
  const root = await Deno.makeTempDir()
  try {
    const target: TargetManifest = {
      ...minimalTarget('Codec', 'cLibrary'),
      manifestDir: join(root, 'Targets/Codec'),
    }
    await Deno.mkdir(join(target.manifestDir, 'Sources', 'Codec.docc'), {
      recursive: true,
    })
    await assertRejects(
      () => generateBuildBazel(basePkg, [target]),
      'cannot document a cLibrary',
    )
  } finally {
    await Deno.remove(root, { recursive: true })
  }
})

Deno.test('unsigned Store profile bypass covers every real Wuhu app and embedded bundle', async () => {
  const source = new URL(
    '../../packages/wuhu-app/Apps/wuhu/app.yml',
    import.meta.url,
  )
  const app = parse(await Deno.readTextFile(source)) as AppManifest
  app.signingTeamID = 'TEAM123456'
  const build = generateAppBuildBazel(app, [], 'Apps/wuhu')
  const bundles = appBundles(app)
  assertEquals(
    bundles.some((bundle) => bundle.name === 'WuhuNotificationService'),
    true,
  )
  assertEquals(bundles.some((bundle) => bundle.name === 'WuhuAppVision'), true)
  assertEquals(
    build.match(/"\/\/bazel\/signing:store_unsigned": None,/g)?.length,
    bundles.length,
  )
  for (const bundle of bundles) {
    assertIncludes(
      build,
      `"//bazel/signing:store": ":${bundle.name}_store_profile__run_deno_task_prepare_profiles"`,
    )
  }
})

Deno.test('rules_apple override patches each touch one file for Bazel native ctx.patch', async () => {
  const template = await Deno.readTextFile(
    new URL('../../MODULE.bazel.template', import.meta.url),
  )
  const override = template.match(
    /single_version_override\(\s*module_name = "rules_apple",[\s\S]*?\n\)/,
  )?.[0]
  if (!override) throw new Error('missing rules_apple single_version_override')
  const patches = [...override.matchAll(/"\/\/bazel\/patches:([^"]+\.patch)"/g)]
    .map((match) => match[1])
  for (
    const platform of ['ios', 'tvos', 'visionos', 'watchos']
  ) {
    assertIncludes(
      patches.join('\n'),
      `rules-apple-unsigned-device-profiles-${platform}.patch`,
    )
  }
  for (const patch of patches) {
    const text = await Deno.readTextFile(
      new URL(`../../bazel/patches/${patch}`, import.meta.url),
    )
    assertEquals({ patch, files: text.match(/^--- /gm)?.length }, {
      patch,
      files: 1,
    })
  }
})
