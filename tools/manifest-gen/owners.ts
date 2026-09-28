import { join, normalize } from '@std/path'
import { parse } from '@std/yaml'
import { moduleFragmentRepos, packageModuleFragment } from './module.ts'

// docs/repo-layout.md laws 2 and 3. `shared` and `wuhu` are public and are
// published; every other owner is private. `wuhu-app` is the closed half of the
// wuhu product (the native app and what only it uses); `internal` is private
// substrate and tooling that ships nowhere and any private owner may use. Of
// the dependency rule only the public edge is enforced: a public package
// reaches public packages only (assertPublicEdges).
export const owners = [
  'shared',
  'wuhu',
  'wuhu-app',
  'internal',
  'arcroom',
  'gika',
  'nobuy-club',
] as const
export type Owner = (typeof owners)[number]

export function isPublicOwner(owner: Owner): boolean {
  return owner === 'shared' || owner === 'wuhu'
}

export function assertOwner(
  owner: unknown,
  source: string,
): asserts owner is Owner {
  if (
    typeof owner !== 'string' || !(owners as readonly string[]).includes(owner)
  ) {
    throw new Error(
      `${source} must declare owner: ${
        owners.join(' | ')
      } (docs/repo-layout.md law 2), not ${JSON.stringify(owner)}.`,
    )
  }
}

// A package directory with a manifest (package.yml, or deno.json for a deno
// package or workspace root), what it references — package directories, and
// `@repo` for an external repository named in a label — and the external
// repositories its own MODULE.fragment.bazel declares.
export interface OwnedPackage {
  dir: string
  owner: Owner
  references: string[]
  repos?: string[]
}

// Every label named anywhere in a parsed manifest that can cross an owner
// boundary: `//packages/...` reduced to its package path
// (`//packages/wuhu-web/app:bundle` -> `packages/wuhu-web/app`), and an external
// repository reduced to `@repo` (`@ffmpeg//:libavcodec` -> `@ffmpeg`).
export function referencedLabelPackages(value: unknown): string[] {
  if (typeof value === 'string') {
    const local = /^\/\/(packages\/[^:]+)(:|$)/.exec(value)
    if (local) return [local[1].replace(/\/+$/, '')]
    const external = /^@@?([A-Za-z0-9_.~+-]+)\/\//.exec(value)
    return external ? [`@${external[1]}`] : []
  }
  if (Array.isArray(value)) return value.flatMap(referencedLabelPackages)
  if (value !== null && typeof value === 'object') {
    return Object.values(value).flatMap(referencedLabelPackages)
  }
  return []
}

// The innermost manifest directory containing `path`: a label may name a
// subdirectory of a package (`//packages/wuhu-core:Targets/...` is the package
// itself; a nested deno member is its own package).
export function owningPackageDir(
  path: string,
  dirs: readonly string[],
): string | undefined {
  let best: string | undefined
  for (const dir of dirs) {
    if (path !== dir && !path.startsWith(`${dir}/`)) continue
    if (best === undefined || dir.length > best.length) best = dir
  }
  return best
}

// A public package may reach only public packages, or the public repo — which
// holds nothing else — does not build. A deno workspace root and each of its
// members reference each other: `deno install` in any member needs every
// member's sources, so a public workspace cannot hold a private member. An
// external repository counts as the package whose MODULE.fragment.bazel
// declares it; one declared elsewhere (the root template, SwiftPM pins) is
// shared infrastructure.
export function assertPublicEdges(packages: readonly OwnedPackage[]): void {
  const byDir = new Map(packages.map((pkg) => [pkg.dir, pkg]))
  const dirs = [...byDir.keys()]
  const repoOwners = new Map<string, string>()
  for (const pkg of packages) {
    for (const repo of pkg.repos ?? []) repoOwners.set(`@${repo}`, pkg.dir)
  }
  const violations: string[] = []
  for (const pkg of packages) {
    for (const reference of pkg.references) {
      if (reference.startsWith('@') && !repoOwners.has(reference)) continue
      const target = repoOwners.get(reference) ??
        owningPackageDir(reference, dirs)
      if (target === undefined) {
        throw new Error(
          `${pkg.dir} references ${reference}, which is inside no package manifest.`,
        )
      }
      if (target === pkg.dir || !isPublicOwner(pkg.owner)) continue
      const targetOwner = byDir.get(target)!.owner
      if (!isPublicOwner(targetOwner)) {
        const via = reference.startsWith('@') ? ` via ${reference}` : ''
        violations.push(
          `${pkg.dir} (owner ${pkg.owner}) -> ${target} (owner ${targetOwner})${via}`,
        )
      }
    }
  }
  if (violations.length) {
    throw new Error(
      `A public package (owner shared or wuhu) depends on a non-public one, so the public repo would not build:\n  ${
        violations.join('\n  ')
      }\nMake the dependency shared, or drop the edge (docs/repo-layout.md).`,
    )
  }
}

async function readTextIfPresent(path: string): Promise<string | undefined> {
  try {
    return await Deno.readTextFile(path)
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return undefined
    throw error
  }
}

async function childDirs(dir: string): Promise<string[]> {
  const dirs: string[] = []
  try {
    for await (const entry of Deno.readDir(dir)) {
      if (entry.isDirectory && entry.name !== 'node_modules') {
        dirs.push(join(dir, entry.name))
      }
    }
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error
  }
  return dirs.sort()
}

async function yamlFiles(
  dir: string,
  name: string,
): Promise<{ path: string; doc: { owner?: unknown } }[]> {
  const docs: { path: string; doc: { owner?: unknown } }[] = []
  for (const child of await childDirs(dir)) {
    const path = join(child, name)
    const text = await readTextIfPresent(path)
    if (text !== undefined) docs.push({ path, doc: parse(text) as object })
  }
  return docs
}

interface DenoManifest {
  owner?: unknown
  workspace?: string[]
  links?: string[]
}

// Swift packages (packages/*/package.yml, with their target.yml and app.yml)
// and deno manifests one or two levels down, as the generator discovers them.
export async function discoverOwnedPackages(
  root = 'packages',
): Promise<OwnedPackage[]> {
  const packages: OwnedPackage[] = []
  for (const dir of await childDirs(root)) {
    const text = await readTextIfPresent(join(dir, 'package.yml'))
    if (text === undefined) continue
    const source = join(dir, 'package.yml')
    const manifest = parse(text) as {
      owner?: unknown
      externalPackages?: Record<string, { path?: string }>
    }
    assertOwner(manifest.owner, source)
    const targets = await yamlFiles(join(dir, 'Targets'), 'target.yml')
    const apps = await yamlFiles(join(dir, 'Apps'), 'app.yml')
    for (const app of apps) {
      assertOwner(app.doc.owner, app.path)
      if (app.doc.owner !== manifest.owner) {
        throw new Error(
          `${app.path} declares owner ${app.doc.owner}, but its package ${source} is ${manifest.owner}; a shell ships its package's code and has its owner.`,
        )
      }
    }
    const paths = Object.values(manifest.externalPackages ?? {})
      .flatMap((external) =>
        external.path ? [normalize(join(dir, external.path))] : []
      )
    const fragment = await readTextIfPresent(join(dir, packageModuleFragment))
    packages.push({
      dir,
      owner: manifest.owner,
      repos: fragment === undefined ? [] : moduleFragmentRepos(fragment),
      references: [
        ...paths,
        ...referencedLabelPackages([
          manifest,
          targets.map((target) => target.doc),
          apps.map((app) => app.doc),
        ]),
      ],
    })
  }

  const denoDirs: string[] = []
  for (const dir of await childDirs(root)) {
    denoDirs.push(dir, ...await childDirs(dir))
  }
  const denoManifests = new Map<string, DenoManifest>()
  for (const dir of denoDirs) {
    const text = await readTextIfPresent(join(dir, 'deno.json'))
    if (text !== undefined) denoManifests.set(dir, JSON.parse(text))
  }
  const workspaceRootOf = new Map<string, string>()
  for (const [dir, manifest] of denoManifests) {
    for (const member of manifest.workspace ?? []) {
      workspaceRootOf.set(normalize(join(dir, member)), dir)
    }
  }
  for (const [dir, manifest] of denoManifests) {
    const source = join(dir, 'deno.json')
    assertOwner(manifest.owner, source)
    const root = workspaceRootOf.get(dir)
    const members = (manifest.workspace ?? []).map((member) =>
      normalize(join(dir, member))
    )
    packages.push({
      dir,
      owner: manifest.owner,
      references: [
        ...(root ? [root] : []),
        ...members,
        ...(manifest.links ?? []).map((link) => normalize(join(dir, link))),
        ...referencedLabelPackages(manifest),
      ],
    })
  }
  return packages.sort((lhs, rhs) => lhs.dir.localeCompare(rhs.dir))
}

// The package directories the public repo carries.
export function publicPackageDirs(packages: readonly OwnedPackage[]): string[] {
  return packages.filter((pkg) => isPublicOwner(pkg.owner)).map((pkg) =>
    pkg.dir
  )
}
