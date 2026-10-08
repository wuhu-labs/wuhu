import { join } from '@std/path'
import {
  cliReleaseTeamID,
  loadTargetManifest,
  releaseApps,
} from './manifests.ts'
import {
  appBundles,
  generateAppBuildBazel,
  populateAppBundleInfo,
  resolvedEntitlements,
  variantBundle,
} from '../manifest-gen/generate.ts'
import { assertEquals } from '../manifest-gen/assertions.ts'

// The BUILD text is the only place the variant mapping actually exists; parsing
// it back is what keeps the release stamp from drifting off the plist a
// sign-store build consumes.
function storeInfoPlists(build: string): Map<string, string> {
  const plists = new Map<string, string>()
  for (const rule of build.split('\n)\n')) {
    const name = /\n {4}name = "([^"]+)",\n/.exec(rule)?.[1]
    const expression = /\n {4}infoplists = ([\s\S]*?),\n {4}minimum_os_version/
      .exec(rule)?.[1]
    if (!name || !expression) continue
    const store = /"\/\/bazel\/signing:store": \["([^"]+)"\]/.exec(expression)
    const plain = /^\["([^"]+)"\]$/.exec(expression)
    const path = store?.[1] ?? plain?.[1]
    if (path) plists.set(name, path)
  }
  return plists
}

async function assertRejects(
  body: () => Promise<unknown>,
  messageIncludes: string,
): Promise<void> {
  try {
    await body()
  } catch (error) {
    if (!String(error).includes(messageIncludes)) {
      throw new Error(
        `Expected error to include ${Deno.inspect(messageIncludes)}, got: ${
          String(error)
        }`,
      )
    }
    return
  }
  throw new Error(
    `Expected a rejection including ${Deno.inspect(messageIncludes)}`,
  )
}

async function writeManifest(path: string, body: string): Promise<void> {
  await Deno.mkdir(join(path, '..'), { recursive: true })
  await Deno.writeTextFile(path, body)
}

async function withSyntheticPackages(
  build: (root: string) => Promise<void>,
  body: (root: string) => Promise<void>,
): Promise<void> {
  const root = await Deno.makeTempDir()
  try {
    await build(root)
    await body(root)
  } finally {
    await Deno.remove(root, { recursive: true })
  }
}

async function writeShell(
  root: string,
  packageName: string,
  shell: string,
  release: string,
): Promise<void> {
  await writeManifest(join(root, packageName, 'package.yml'), 'name: x\n')
  await writeShellManifest(
    join(root, packageName, 'Apps', shell),
    `name: ${shell}\nrelease:\n  name: ${release}\n  platforms:\n    - mac\n` +
      `targets:\n  - name: ${shell}Mac\n    platform: macOS\n` +
      `    bundleID: ms.liu.${shell}\n` +
      `    infoPlist: Sources/Info.plist\n    entitlements: {}\n`,
  )
}

// The reader resolves each target's declared entitlements, so a synthetic shell
// carries the file it names rather than a target stub that cannot be read.
async function writeShellManifest(dir: string, body: string): Promise<void> {
  await writeManifest(join(dir, 'app.yml'), body)
  await writeManifest(
    join(dir, 'Shell.entitlements'),
    '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict/>\n</plist>\n',
  )
}

Deno.test('the repo declares every app release lane', async () => {
  assertEquals(
    (await releaseApps()).map((app) => [app.name, app.dir]),
    [
      ['arcroom', 'packages/arcroom/Apps/arcroom'],
      ['gika', 'packages/gika/Apps/gika'],
      ['nobuy-club', 'packages/nobuy-club/Apps/nobuy'],
      ['wuhu-app', 'packages/wuhu-app/Apps/wuhu'],
    ],
  )
})

// A target existing does not create a release lane; declaring one does. The
// difference is not cosmetic: bazel refuses to analyse a device slice with no
// store provisioning profile. A shell may therefore build a platform it never
// publishes, but never publish a platform it cannot build.
Deno.test('a release lane is declared, not inferred from the targets', async () => {
  await withSyntheticPackages(
    async (root) => {
      await writeManifest(join(root, 'one', 'package.yml'), 'name: x\n')
      await writeShellManifest(
        join(root, 'one', 'Apps', 'one'),
        'name: one\nrelease:\n  name: one\n  platforms:\n    - ios\n' +
          'targets:\n  - name: oneMac\n    platform: macOS\n' +
          '    bundleID: ms.liu.one\n' +
          '    infoPlist: Sources/Info.plist\n    entitlements: {}\n' +
          '  - name: oneIOS\n    platform: iOS\n' +
          '    bundleID: ms.liu.one\n' +
          '    infoPlist: Sources/Info-iOS.plist\n    entitlements: {}\n',
      )
    },
    async (root) => {
      const [app] = await releaseApps(root)
      assertEquals(
        new Set(app.targets.map((target) => target.platform)),
        new Set(['mac', 'ios']),
      )
      assertEquals(app.defaultPlatforms, ['ios'])
    },
  )
  for (const app of await releaseApps()) {
    const targets = new Set(app.targets.map((target) => target.platform))
    for (const lane of app.defaultPlatforms) {
      assertEquals(targets.has(lane), true)
    }
  }
})

Deno.test('a lane with no target fails the app manifest', async () => {
  await withSyntheticPackages(
    async (root) => {
      await writeManifest(
        join(root, 'one', 'package.yml'),
        'name: x\n',
      )
      await writeShellManifest(
        join(root, 'one', 'Apps', 'one'),
        'name: one\nrelease:\n  name: one\n  platforms:\n    - tvos\n' +
          'targets:\n  - name: oneMac\n    platform: macOS\n' +
          '    infoPlist: Sources/Info.plist\n    entitlements: {}\n',
      )
    },
    (root) =>
      assertRejects(
        () => releaseApps(root),
        'release.platforms names tvos but no target builds for it',
      ),
  )
})

Deno.test('the release view names the plist a sign-store build consumes', async () => {
  for (const app of await releaseApps()) {
    const plists = storeInfoPlists(generateAppBuildBazel(app.manifest))
    for (const target of app.targets) {
      assertEquals(
        [target.name, target.releaseInfoPlist],
        [target.name, join(app.dir, plists.get(target.name)!)],
      )
    }
  }
})

// RosterStore and WidgetFiles find the container through WuhuAppGroup, so a
// bundle whose plist names another group than it is entitled to reads nothing.
Deno.test('every wuhu iOS bundle names its own app group in both identities', async () => {
  const wuhu = (await releaseApps()).find((app) => app.name === 'wuhu-app')!
  const manifest = structuredClone(wuhu.manifest)
  populateAppBundleInfo(manifest)
  const checked: string[] = []
  for (const bundle of appBundles(manifest)) {
    if (bundle.platform !== 'iOS') continue
    for (const variant of ['dev', 'adhoc', 'store'] as const) {
      const signed = variantBundle(bundle, variant)
      const groups = resolvedEntitlements(bundle, variant, 'TEAM123456')[
        'com.apple.security.application-groups'
      ] as string[] | undefined
      assertEquals(
        [signed.bundleID, signed.info.WuhuAppGroup],
        [signed.bundleID, groups?.[0]],
      )
      checked.push(signed.bundleID)
    }
  }
  assertEquals([...new Set(checked)].sort(), [
    'ai.wuhu.app',
    'ai.wuhu.app.NotificationService',
    'ai.wuhu.app.Widgets',
    'ai.wuhu.app.dev',
    'ai.wuhu.app.dev.NotificationService',
    'ai.wuhu.app.dev.Widgets',
  ])
})

Deno.test('the Gika iOS archive stamps its embedded Watch application', async () => {
  const gika = (await releaseApps()).find((app) => app.name === 'gika')!
  const ios = gika.targets.find((target) => target.platform === 'ios')!
  assertEquals(
    ios.embeddedInfoPlists.includes(
      'packages/gika/Apps/gika/Watch/BazelInfo.plist',
    ),
    true,
  )
})

Deno.test('the wuhu CLI declares its own signing team', async () => {
  assertEquals(await cliReleaseTeamID(), '97W7A3Y9GD')
})

Deno.test('a malformed teamID fails the target manifest', async () => {
  await withSyntheticPackages(
    async (root) => {
      await writeManifest(
        join(root, 'target.yml'),
        'name: wuhu\nkind: executable\nsources: Sources\nrelease:\n  teamID: "97W7A3Y9"\n',
      )
    },
    async (root) => {
      await assertRejects(
        () => loadTargetManifest(join(root, 'target.yml')),
        'release.teamID must be 10 characters of A-Z0-9',
      )
    },
  )
})

Deno.test('a non-kebab-case release name fails the app manifest', async () => {
  await withSyntheticPackages(
    (root) => writeShell(root, 'one', 'one', 'Wuhu_App'),
    (root) =>
      assertRejects(
        () => releaseApps(root),
        'release.name must be kebab-case',
      ),
  )
})

Deno.test('two shells cannot claim one release namespace', async () => {
  await withSyntheticPackages(
    async (root) => {
      await writeShell(root, 'one', 'one', 'shared')
      await writeShell(root, 'two', 'two', 'shared')
    },
    (root) =>
      assertRejects(
        () => releaseApps(root),
        'release namespace shared is claimed by both',
      ),
  )
})

Deno.test('a shell cannot claim the CLI release namespace', async () => {
  await withSyntheticPackages(
    async (root) => {
      await writeShell(root, 'one', 'one', 'wuhu')
      await writeManifest(
        join(root, 'wuhu-core', 'Targets', 'wuhu', 'target.yml'),
        'name: wuhu\nkind: executable\nsources: Sources\nrelease:\n  teamID: "97W7A3Y9GD"\n',
      )
    },
    (root) =>
      assertRejects(
        () => releaseApps(root),
        'release namespace wuhu is claimed by both',
      ),
  )
})

Deno.test('the existing Store release plan never selects the direct Mac edition', async () => {
  const app = (await releaseApps()).find((app) => app.name === 'wuhu-app')!
  assertEquals(app.targets.map((target) => target.name), [
    'WuhuApp',
    'WuhuAppIOS',
    'WuhuAppVision',
  ])
  assertEquals(
    app.targets.every((target) => target.bundleID === 'ai.wuhu.app'),
    true,
  )
})
