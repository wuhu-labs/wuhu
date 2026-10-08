import { basename, dirname, join } from '@std/path'
import { parse } from '@std/yaml'
import {
  type AppManifest,
  type AppTargetManifest,
  assertReleaseNamespacesDistinct,
  bundleEmbedsViewPilot,
  discoverAppDirs,
  discoverPackageDirs,
  infoPlistPaths,
  type TargetManifest,
  validateAppEntitlements,
  validateAppExtensions,
  validateAppIntents,
  validateAppRelease,
  validateTargetInfo,
  validateTargetRelease,
} from '../manifest-gen/generate.ts'
import { type Platform, platformOfManifest } from './plan.ts'

export type {
  AppManifest,
  AppReleaseManifest,
  TargetManifest,
  TargetReleaseManifest,
} from '../manifest-gen/generate.ts'

export { discoverAppDirs, discoverPackageDirs }

const cliTargetPath = 'packages/wuhu-core/Targets/wuhu/target.yml'

export async function loadAppManifest(dir: string): Promise<AppManifest> {
  const source = join(dir, 'app.yml')
  const app = parse(await Deno.readTextFile(source)) as AppManifest
  validateAppRelease(app, source)
  validateAppExtensions(app, source)
  validateAppIntents(app, source)
  validateAppEntitlements(app, source)
  return app
}

export async function loadTargetManifest(
  path: string,
): Promise<TargetManifest> {
  const target = parse(await Deno.readTextFile(path)) as Omit<
    TargetManifest,
    'manifestDir'
  >
  const resolved = { ...target, manifestDir: dirname(path) }
  validateTargetRelease(resolved)
  validateTargetInfo(resolved)
  return resolved
}

export interface ReleaseTargetView {
  readonly name: string
  readonly platform: Platform
  readonly bundleID: string
  readonly bundleName: string
  readonly releaseInfoPlist: string
  readonly embeddedInfoPlists: readonly string[]
  readonly teamID: string | null
  readonly keychainAccessGroups: readonly string[]
}

export interface ReleaseAppView {
  readonly name: string
  readonly dir: string
  readonly manifest: AppManifest
  readonly displayName: string
  readonly manifestPath: string
  readonly bazelPackage: string
  readonly defaultPlatforms: readonly Platform[]
  readonly targets: readonly ReleaseTargetView[]
}

export async function appViews(root = 'packages'): Promise<ReleaseAppView[]> {
  const apps: ReleaseAppView[] = []
  const teamID = await releaseSigningTeamID()
  for (const packageDir of await discoverPackageDirs(root)) {
    for (const dir of await discoverAppDirs(packageDir)) {
      apps.push(releaseAppView(dir, await loadAppManifest(dir), teamID))
    }
  }
  return apps.sort((lhs, rhs) => lhs.name.localeCompare(rhs.name))
}

export async function releaseApps(
  root = 'packages',
): Promise<ReleaseAppView[]> {
  const apps = (await appViews(root)).filter((app) => app.manifest.release)
  assertReleaseNamespacesDistinct([
    ...apps.map((app) => ({ name: app.name, source: app.dir })),
    ...await executableReleaseNamespaces(root),
  ])
  return apps
}

function releaseAppView(
  dir: string,
  manifest: AppManifest,
  teamID: string,
): ReleaseAppView {
  const targets: ReleaseTargetView[] = []
  const extensions = new Map(
    (manifest.extensions ?? []).map((target) => [target.name, target]),
  )
  const watchApplications = new Map(
    (manifest.watchApplications ?? []).map((target) => [target.name, target]),
  )
  // A release archive stamps the plists the store variant selects.
  for (
    const target of manifest.targets.filter((target) =>
      target.distribution !== 'direct'
    )
  ) {
    targets.push({
      name: target.name,
      platform: platformOfManifest(target.platform),
      bundleID: target.bundleID,
      bundleName: target.bundleName,
      releaseInfoPlist: join(
        dir,
        infoPlistPaths(target, bundleEmbedsViewPilot(manifest, target)).store,
      ),
      embeddedInfoPlists: [
        ...(target.extensions ?? []).map((name) => {
          const extension = extensions.get(name)
          if (!extension) {
            throw new Error(
              `${dir}/app.yml: ${target.name} embeds unknown extension ${name}`,
            )
          }
          return join(dir, infoPlistPaths(extension, false).store)
        }),
        ...(target.watchApplication === undefined ? [] : [
          join(
            dir,
            watchApplications.get(target.watchApplication)!.infoPlist,
          ),
        ]),
      ],
      teamID,
      keychainAccessGroups: keychainAccessGroups(target),
    })
  }
  return {
    name: manifest.release?.name ?? basename(dir),
    dir,
    manifest,
    displayName: manifest.name,
    manifestPath: join(dir, 'app.yml'),
    bazelPackage: `//${dirname(dirname(dir))}`,
    defaultPlatforms: manifest.release?.platforms ?? [],
    targets,
  }
}

function keychainAccessGroups(
  target: AppTargetManifest,
): readonly string[] {
  const value = {
    ...(target.entitlements.common ?? {}),
    ...(target.entitlements.release ?? {}),
  }['keychain-access-groups']
  if (value === undefined) return []
  if (
    !Array.isArray(value) || value.some((entry) => typeof entry !== 'string')
  ) {
    throw new Error(
      `${target.name}.entitlements keychain-access-groups is not a string array`,
    )
  }
  return value as string[]
}

async function releaseSigningTeamID(): Promise<string> {
  const config = parse(
    await Deno.readTextFile('tools/signing/signing.yml'),
  ) as { team?: string }
  if (!config.team || !/^[A-Z0-9]{10}$/.test(config.team)) {
    throw new Error('tools/signing/signing.yml has no valid team')
  }
  return config.team
}

export async function cliReleaseTeamID(root = 'packages'): Promise<string> {
  const path = cliManifestPath(root)
  const target = await loadTargetManifest(path)
  if (!target.release) {
    throw new Error(
      `${path} declares no release block; the wuhu CLI signing identity lives there`,
    )
  }
  return target.release.teamID
}

export async function cliBundleIdentifier(root = 'packages'): Promise<string> {
  const path = cliManifestPath(root)
  const identifier = (await loadTargetManifest(path)).info?.CFBundleIdentifier
  if (typeof identifier !== 'string') {
    throw new Error(
      `${path} declares no info.CFBundleIdentifier; the wuhu CLI's code-signing identifier lives there`,
    )
  }
  return identifier
}

function cliManifestPath(root: string): string {
  return join(root, cliTargetPath.slice('packages/'.length))
}

async function executableReleaseNamespaces(
  root: string,
): Promise<{ name: string; source: string }[]> {
  const path = cliManifestPath(root)
  const target = await loadTargetManifest(path).catch((error: unknown) => {
    if (error instanceof Deno.errors.NotFound) return null
    throw error
  })
  if (!target?.release) return []
  return [{ name: target.name, source: path }]
}
