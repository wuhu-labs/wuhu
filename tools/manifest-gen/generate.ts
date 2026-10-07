import { basename, dirname, join, normalize, relative } from '@std/path'
import { parse } from '@std/yaml'
import {
  type LocalPackageRef,
  workspaceContents,
  type WorkspaceLocalConfig,
  xcodeInfoPlist,
  xcodeInfoPlistPath,
  xcodeProjectSpec,
  xcodeShellSource,
  xcodeShellSourcePath,
} from './xcode-workspace.ts'
import {
  type Platform as ReleasePlatform,
  platformOfManifest as appPlatformLane,
  platforms as releasePlatforms,
} from '../lib/plan.ts'
import { manifestFingerprint } from './provenance.ts'
import {
  pinnedRepos,
  readConfigureFragments,
  readPackageModules,
  renderModuleBazel,
} from './module.ts'
import {
  assertOwner,
  assertPublicEdges,
  discoverOwnedPackages,
  type Owner,
} from './owners.ts'

export type { ReleasePlatform }

export type CheckPlatform =
  | 'linux'
  | 'mac'
  | 'ios'
  | 'tvos'
  | 'visionos'
  | 'watchos'

export interface Checks {
  build?: CheckPlatform[]
  test?: CheckPlatform[]
}

export interface PackageManifest {
  name: string
  owner: Owner
  swiftToolsVersion: string
  packageName: string
  products?: string[] | 'all'
  defaultLocalization?: string
  platforms?: Record<string, string>
  checks?: Checks
  externalPackages?: Record<string, ExternalPackage>
}

export interface ExternalPackage {
  url?: string
  path?: string
  exact?: string
  from?: string
  revision?: string
  branch?: string
  traits?: string[]
  // Optional overrides for the Bazel label prefix. When absent the generator
  // derives them: `bazelRepo` from the URL via the rules_swift_package_manager
  // convention, `bazelPackage` from the local `path`. Keep them only when a
  // fetched package needs `configure_package(repo_name = ...)` to diverge.
  bazelRepo?: string
  bazelPackage?: string
  // Product names this external exposes. A list means each product maps to a
  // same-named Bazel target label (the rspm convention for fetched packages and
  // our own `wuhu_swift_library(name = target.name)` emission for local ones). A
  // map `{ product: targetLabel }` is the escape hatch for the rare product
  // whose target label differs from its product name.
  products: string[] | Record<string, string>
  // Resolved during load, never authored: the SwiftPM package identity used as
  // the `package:` argument in `.product(...)` and as the dedup key for the
  // umbrella manifest. Derived from the URL (remote) or the dependency
  // package's own `name` (local), so the YAML map key stays a pure label.
  identity?: string
}

const issueReportingTestSupport: ExternalPackage = {
  url: 'https://github.com/pointfreeco/xctest-dynamic-overlay',
  from: '1.0.0',
  identity: 'xctest-dynamic-overlay',
  bazelRepo: 'swiftpkg_xctest_dynamic_overlay',
  products: ['IssueReportingTestSupport'],
}

function testSupportPackages(
  pkg: PackageManifest,
): Record<string, ExternalPackage> {
  return {
    'xctest-dynamic-overlay': issueReportingTestSupport,
    ...pkg.externalPackages,
  }
}

interface BinaryTargetLowering {
  url: string
  checksum: string
}

interface UpstreamFetch {
  url: string
  sha256: string
  stripPrefix?: string
}

interface CTargetLowering {
  module: string
  fetch: UpstreamFetch
  sources: string[]
  publicHeader: string
  // `sources` names directories, which SwiftPM walks recursively; the Bazel
  // side globs one level. Anything the glob would not have matched is excluded
  // here so both graphs compile the same translation units.
  exclude?: string[]
  defines?: string[]
  // Resolved by SwiftPM against the target's own path. A bare `-I` in
  // `unsafeFlags` is not: it reaches the compiler verbatim and resolves
  // against the build's working directory, so the header is never found.
  headerSearchPaths?: string[]
  unsafeFlags?: string[]
  linuxLibraries?: string[]
}

// A raw Bazel label names a repository the SwiftPM graph cannot see (a pinned
// `http_archive`), so every such dependency must also declare how SwiftPM
// obtains the same artifact: a `binaryTarget` (a hosted xcframework zip) or a
// `cTarget` (a sha256-pinned source checkout compiled as a local C target —
// local because SwiftPM rejects unsafeFlags in remote dependencies).
interface SwiftPMLowering {
  binaryTarget?: BinaryTargetLowering
  cTarget?: CTargetLowering
}

interface DependencyOptions {
  name: string
  bazel?: boolean
  swiftpm?: SwiftPMLowering
}

type Dependency = string | DependencyOptions

interface Resource {
  path: string
  mode: 'copy' | 'process'
}

// Exactly one of `path` (a folder under the target's sources, excluded from the
// SwiftPM target), `packagePath` (a folder elsewhere in the same Bazel package,
// so nothing to exclude) or `target` (a Bazel label producing a directory, e.g.
// a deno_bundle — Bazel-only by construction, nothing to exclude).
interface EmbeddedResource {
  name: string
  path?: string
  packagePath?: string
  target?: string
  typeName: string
  symbolName?: string
}

interface SwiftSetting {
  enableExperimentalFeature?: string
  define?: string
  unsafeFlags?: string[]
}

const testSizes = ['small', 'medium', 'large', 'enormous'] as const
type TestSize = (typeof testSizes)[number]

interface TestConfig {
  dependencies?: Dependency[]
  resources?: Resource[]
  // Folders elsewhere in the same Bazel package that the tests read back by
  // path (`#filePath`-relative). Runfiles only — no resource bundle, and no
  // SwiftPM counterpart, where the same relative path resolves in the checkout.
  data?: string[]
  // Labels of external-repository files the tests read at run time (a pinned
  // fixture corpus). Emitted into `extra_data` verbatim; Bazel-only, like
  // `data`, and reaching one from the test needs an `env` entry whose value
  // uses `$(rootpath <label>)`.
  externalData?: string[]
  // Environment for the Bazel test action. Bazel-only: SwiftPM has no
  // equivalent, and a test that NEEDS an env var to be correct belongs on the
  // Bazel path anyway.
  env?: Record<string, string>
  // Names a simulator lane forwards from the test action into the simulator
  // process. `--test_env=NAME` reaches the runner on its own; nothing carries
  // it across `simctl spawn` without this.
  envInherit?: string[]
  // Per simulator lane, the application the test bundle runs inside instead
  // of the bare `xctest` agent: a real UIApplication with a connected scene.
  // Bazel-only, like `env`.
  host?: Partial<Record<CheckPlatform, string>>
  // false keeps the test target, folder and references included, out of the
  // public tree (tools/public/tree.ts dropPrivateTests). Generation ignores it.
  public?: boolean
  exclude?: string[]
  swiftSettings?: SwiftSetting[]
  size?: TestSize
  tags?: string[]
  checks?: Pick<Checks, 'test'>
}

interface AdditionalTestTarget extends TestConfig {
  sources: string
}

// A target whose `Sources/*.swift` are produced by apple/swift-openapi-generator
// from the canonical OpenAPI document. The BUILD emitter replaces the usual
// `srcs = glob(...)` with `srcs = [":<name>_gen"]` pointing at a `wuhu_openapi_sources`
// rule (see bazel/rules/rules.bzl); the SwiftPM emitter is unchanged (it globs
// `Sources/`, which the `deno task generate-openapi` escape hatch materializes).
interface OpenApiGenerateConfig {
  // Path to the OpenAPI document, relative to the package root.
  document: string
  // Path to the swift-openapi-generator config, relative to the target directory.
  config: string
  // The single `.swift` file the generator writes into the output directory for
  // this config's `generate` mode (types -> Types.swift, client -> Client.swift,
  // server -> Server.swift).
  output: string
}

export type TargetKind =
  | 'library'
  | 'executable'
  | 'macro'
  | 'objcLibrary'
  | 'systemLibrary'

export interface TargetReleaseManifest {
  teamID: string
}

export interface TargetManifest {
  name: string
  productName?: string
  kind: TargetKind
  sources: string
  dependencies?: Dependency[]
  resources?: Resource[]
  embeddedResources?: EmbeddedResource[]
  tests?: TestConfig | false
  additionalTestTargets?: AdditionalTestTarget[]
  openapiGenerate?: OpenApiGenerateConfig
  swiftSettings?: SwiftSetting[]
  checks?: Checks
  // Extra copts-symbol names loaded from //bazel/rules:rules.bzl.
  copts?: string[]
  // systemLibrary only: apt packages for SwiftPM `.systemLibrary` providers, and
  // system libraries to link (Bazel `-l<name>` linkopts; the modulemap's own
  // `link` directive covers Darwin autolink).
  apt?: string[]
  link?: string[]
  // library only: SDK frameworks the binary must load even when no symbol in
  // it references them, e.g. the superclass of an overlay's subclass.
  linkedFrameworks?: string[]
  stamp?: boolean
  // An executable's embedded Info.plist (macOS only); the version keys are
  // stamped, so it requires `stamp: true`.
  info?: { [key: string]: PlistValue }
  // An executable that ships as a signed artifact declares the Apple team it
  // ships under; its tag namespace is the target name.
  release?: TargetReleaseManifest
  manifestDir: string
}

interface ResolvedTestTarget {
  name: string
  sources: string
  config: TestConfig
}

function testTargets(target: TargetManifest): ResolvedTestTarget[] {
  if (target.tests && 'sources' in target.tests) {
    throw new Error(
      `${target.manifestDir}/target.yml uses retired tests.sources; the primary test target always uses Tests`,
    )
  }

  const tests: ResolvedTestTarget[] = target.tests
    ? [{ name: `${target.name}Tests`, sources: 'Tests', config: target.tests }]
    : []
  for (const config of target.additionalTestTargets ?? []) {
    if (!config.sources) {
      throw new Error(
        `${target.manifestDir}/target.yml additionalTestTargets entries must declare sources`,
      )
    }
    const folder = basename(config.sources)
    if (!folder || folder === '.') {
      throw new Error(
        `${target.manifestDir}/target.yml has invalid additional test sources ${
          JSON.stringify(config.sources)
        }`,
      )
    }
    tests.push({
      name: `${target.name}${folder}`,
      sources: config.sources,
      config,
    })
  }

  const names = new Set<string>()
  for (const test of tests) {
    if (names.has(test.name)) {
      throw new Error(
        `${target.manifestDir}/target.yml declares duplicate test target ${test.name}`,
      )
    }
    names.add(test.name)
  }
  return tests
}

export type PlistValue =
  | string
  | number
  | boolean
  | PlistValue[]
  | { [key: string]: PlistValue }

export interface AppLibraryManifest {
  name: string
  // One directory, or several that compile into a single Swift module. Shells
  // routinely share files across platforms (a common browse surface, a route
  // resolver) and those files use internal access across directories, so the
  // grouping is a module boundary rather than a directory boundary.
  sources: string | string[]
  dependencies?: string[]
  // Extra copts-symbol names from //bazel/rules:rules.bzl to append after the
  // base language-mode copts (e.g. "WUHU_UI_CONTROL_COPTS" to thread the
  // dev-only BUILD_WITH_UI_CONTROL define into the raw-swift_library app shell).
  copts?: string[]
}

export interface EntitlementOverlays {
  common?: { [key: string]: PlistValue }
  dev?: { [key: string]: PlistValue }
  release?: { [key: string]: PlistValue }
}

// The identity the dev and adhoc variants sign as, so a development build
// installs beside the store app instead of replacing it. Each field overrides
// the bundle's own; `entitlements` merges over `entitlements.common`.
export interface DevIdentityManifest {
  bundleID: string
  displayName?: string
  appIcons?: string[]
  entitlements?: { [key: string]: PlistValue }
  info?: { [key: string]: PlistValue }
}

export interface AppBundleManifest {
  name: string
  platform: 'macOS' | 'iOS' | 'tvOS' | 'visionOS' | 'watchOS'
  bundleID: string
  bundleName: string
  displayName?: string
  entitlements: EntitlementOverlays
  devIdentity?: DevIdentityManifest
  families: string[]
  appIcons: string[]
  resources?: string[]
  infoPlist: string
  minimumOSVersion: string
  dependencies: string[]
  // Shell libraries whose AppIntents this bundle publishes. Without it the
  // bundle ships no Metadata.appintents, and every AppIntent the code declares
  // — App Shortcuts, widget and Live Activity `Button(intent:)` — is inert at
  // runtime while still compiling and linking fine.
  appIntents?: string[]
  frameworks?: string[]
  linkopts?: string[]
  info: { [key: string]: PlistValue }
}

export type AppExtensionManifest = AppBundleManifest

export interface AppTargetManifest extends AppBundleManifest {
  extensions?: string[]
  watchApplication?: string
}

export interface AppReleaseManifest {
  name: string
  // The lanes this shell releases. A target existing does not create a lane;
  // declaring one does, and the release workflow reads its matrix from here.
  platforms: ReleasePlatform[]
}

export interface AppManifest {
  name: string
  viewPilot?: boolean
  marketingVersion?: string
  developmentRegion?: string
  usesNonExemptEncryption?: boolean
  // Presence means this shell has a release lane; `name` is its tag namespace.
  release?: AppReleaseManifest
  libraries?: AppLibraryManifest[]
  extensions?: AppExtensionManifest[]
  watchApplications?: AppBundleManifest[]
  targets: AppTargetManifest[]
  signingTeamID?: string
}

const teamIDPattern = /^[A-Z0-9]{10}$/
const releaseNamePattern = /^[a-z0-9]+(-[a-z0-9]+)*$/

export function validateTargetRelease(target: TargetManifest): void {
  const release = target.release
  if (!release) return
  if (target.kind !== 'executable') {
    throw new Error(
      `${target.name} declares release: but is a ${target.kind}, not an executable`,
    )
  }
  if (!teamIDPattern.test(release.teamID)) {
    throw new Error(
      `${target.name} release.teamID must be 10 characters of A-Z0-9, got ${
        JSON.stringify(release.teamID)
      }`,
    )
  }
}

export function validateTargetLinkedFrameworks(target: TargetManifest): void {
  if (target.linkedFrameworks && target.kind !== 'library') {
    throw new Error(
      `${target.name} declares linkedFrameworks: but is kind ${target.kind}, not library`,
    )
  }
}

const stampedInfoKeys = ['CFBundleShortVersionString', 'CFBundleVersion']

export function validateTargetInfo(target: TargetManifest): void {
  const info = target.info
  if (!info) return
  if (target.kind !== 'executable' || !target.stamp) {
    throw new Error(
      `${target.name} declares info: but is not a stamped executable (kind: executable, stamp: true)`,
    )
  }
  if (typeof info !== 'object' || Array.isArray(info)) {
    throw new Error(`${target.name}.info must be a dictionary`)
  }
  assertPlistValues(info, `${target.name}.info`)
  if (typeof info.CFBundleIdentifier !== 'string') {
    throw new Error(`${target.name}.info must declare CFBundleIdentifier`)
  }
  for (const key of stampedInfoKeys) {
    if (key in info) {
      throw new Error(
        `${target.name}.info.${key} is stamped from the release version and must not be authored`,
      )
    }
  }
}

export function validateAppRelease(app: AppManifest, source: string): void {
  const release = app.release
  if (!release) return
  if (!releaseNamePattern.test(release.name)) {
    throw new Error(
      `${source} release.name must be kebab-case, got ${
        JSON.stringify(release.name)
      }`,
    )
  }
  if (!Array.isArray(release.platforms) || release.platforms.length === 0) {
    throw new Error(
      `${source} release.platforms must list at least one of ${
        releasePlatforms.join(', ')
      }`,
    )
  }
  for (const platform of release.platforms) {
    if (!releasePlatforms.includes(platform)) {
      throw new Error(
        `${source} release.platforms has unknown lane ${
          JSON.stringify(platform)
        }; known lanes are ${releasePlatforms.join(', ')}`,
      )
    }
    const declared = app.targets.some((target) =>
      appPlatformLane(target.platform) === platform
    )
    if (!declared) {
      throw new Error(
        `${source} release.platforms names ${platform} but no target builds for it`,
      )
    }
  }
}

export function validateAppExtensions(app: AppManifest, source: string): void {
  const extensions = new Map(
    (app.extensions ?? []).map((target) => [target.name, target]),
  )
  for (const target of app.targets) {
    for (const name of target.extensions ?? []) {
      const extension = extensions.get(name)
      if (!extension) {
        throw new Error(
          `${source}: ${target.name} embeds ${name}, which app.yml does not declare as an extension`,
        )
      }
      if (extension.platform !== target.platform) {
        throw new Error(
          `${source}: ${target.name} (${target.platform}) cannot embed ${name} (${extension.platform})`,
        )
      }
    }
    if (target.watchApplication === undefined) continue
    const watch = (app.watchApplications ?? []).find((candidate) =>
      candidate.name === target.watchApplication
    )
    if (!watch) {
      throw new Error(
        `${source}: ${target.name} embeds ${target.watchApplication}, which app.yml does not declare as a watch application`,
      )
    }
    if (target.platform !== 'iOS') {
      throw new Error(
        `${source}: ${target.name} (${target.platform}) cannot embed a watch application`,
      )
    }
  }

  const references = app.targets.flatMap((target) =>
    target.watchApplication === undefined ? [] : [target.watchApplication]
  )
  for (const watch of app.watchApplications ?? []) {
    if (watch.platform !== 'watchOS') {
      throw new Error(
        `${source}: ${watch.name} watch application must target watchOS`,
      )
    }
    const count = references.filter((name) => name === watch.name).length
    if (count !== 1) {
      throw new Error(
        `${source}: ${watch.name} watch application must have exactly one iOS companion`,
      )
    }
  }
}

export function appIntentsLibraries(app: AppManifest): Set<string> {
  return new Set(
    appBundles(app).flatMap((target) =>
      (target.appIntents ?? []).map((label) => label.slice(1))
    ),
  )
}

export function validateAppIntents(app: AppManifest, source: string): void {
  const libraries = new Set(
    (app.libraries ?? []).map((library) => library.name),
  )
  for (const target of appBundles(app)) {
    for (const label of target.appIntents ?? []) {
      if (!label.startsWith(':') || !libraries.has(label.slice(1))) {
        throw new Error(
          `${source}: ${target.name} declares appIntents ${label}, which is not a library this shell declares`,
        )
      }
      // appintentsmetadataprocessor reads the library's const values, but the
      // intents only exist at runtime if the same library is linked in.
      if (!target.dependencies.includes(label)) {
        throw new Error(
          `${source}: ${target.name} declares appIntents ${label} without depending on it`,
        )
      }
    }
  }
}

export function validateAppEntitlements(
  app: AppManifest,
  source: string,
): void {
  const generatedKeys = new Set([
    'application-identifier',
    'com.apple.application-identifier',
    'com.apple.developer.team-identifier',
    'get-task-allow',
  ])
  for (
    const target of [
      ...app.targets,
      ...(app.extensions ?? []),
      ...(app.watchApplications ?? []),
    ]
  ) {
    const declaration = target.entitlements
    if (
      typeof declaration !== 'object' || declaration === null ||
      Array.isArray(declaration)
    ) {
      throw new Error(
        `${source}: ${target.name}.entitlements must be a common/dev/release mapping`,
      )
    }
    const unknown = Object.keys(declaration).filter((key) =>
      !['common', 'dev', 'release'].includes(key)
    )
    if (unknown.length > 0) {
      throw new Error(
        `${source}: ${target.name}.entitlements has unknown overlays ${
          unknown.join(', ')
        }`,
      )
    }
    const checkAuthored = (values: unknown, label: string): void => {
      if (
        typeof values !== 'object' || values === null || Array.isArray(values)
      ) {
        throw new Error(`${source}: ${label} must be a dictionary`)
      }
      assertPlistValues(
        values as Record<string, unknown>,
        `${source}: ${label}`,
      )
      for (const key of Object.keys(values)) {
        if (generatedKeys.has(key)) {
          throw new Error(
            `${source}: ${label}.${key} is generated and must not be authored`,
          )
        }
      }
    }
    for (const [overlay, values] of Object.entries(declaration)) {
      checkAuthored(values, `${target.name}.entitlements.${overlay}`)
    }
    if (target.devIdentity?.entitlements !== undefined) {
      checkAuthored(
        target.devIdentity.entitlements,
        `${target.name}.devIdentity.entitlements`,
      )
    }
  }
  validateDevIdentities(app, source)
}

function validateDevIdentities(app: AppManifest, source: string): void {
  for (const target of appBundles(app)) {
    const identity = target.devIdentity
    if (identity === undefined) continue
    if (typeof identity.bundleID !== 'string' || identity.bundleID === '') {
      throw new Error(`${source}: ${target.name}.devIdentity needs a bundleID`)
    }
    if (isPreviewBundle(target) || isPreviewBundle(identity)) {
      throw new Error(
        `${source}: ${target.name} is a preview bundle, which has a single identity`,
      )
    }
    if (identity.bundleID === target.bundleID) {
      throw new Error(
        `${source}: ${target.name}.devIdentity.bundleID repeats the store bundle ID`,
      )
    }
  }
  const extensions = new Map(
    (app.extensions ?? []).map((target) => [target.name, target]),
  )
  for (const target of app.targets) {
    for (const name of target.extensions ?? []) {
      const extension = extensions.get(name)
      if (extension === undefined) continue
      if (
        (target.devIdentity === undefined) !==
          (extension.devIdentity === undefined)
      ) {
        throw new Error(
          `${source}: ${target.name} and its extension ${name} must both declare a devIdentity or neither`,
        )
      }
      if (
        target.devIdentity !== undefined &&
        !extension.devIdentity!.bundleID.startsWith(
          `${target.devIdentity.bundleID}.`,
        )
      ) {
        throw new Error(
          `${source}: ${name}.devIdentity.bundleID must extend ${target.devIdentity.bundleID}`,
        )
      }
    }
    if (target.watchApplication !== undefined && target.devIdentity) {
      throw new Error(
        `${source}: ${target.name} embeds a watch application, which devIdentity does not support yet`,
      )
    }
  }
}

export function validateAppTransportSecurity(
  value: unknown,
  source: string,
): void {
  if (Array.isArray(value)) {
    value.forEach((item, index) =>
      validateAppTransportSecurity(item, `${source}[${index}]`)
    )
    return
  }
  if (value === null || typeof value !== 'object') return
  const dictionary = value as Record<string, unknown>
  const ats = dictionary.NSAppTransportSecurity as
    | Record<string, unknown>
    | undefined
  if (ats?.NSAllowsArbitraryLoads === true) {
    for (
      const key of [
        'NSAllowsLocalNetworking',
        'NSAllowsArbitraryLoadsForMedia',
        'NSAllowsArbitraryLoadsInWebContent',
      ]
    ) {
      if (ats[key] !== undefined) {
        throw new Error(
          `${source}.NSAppTransportSecurity combines NSAllowsArbitraryLoads with ${key}, which overrides it`,
        )
      }
    }
  }
  for (const [key, item] of Object.entries(dictionary)) {
    validateAppTransportSecurity(item, `${source}.${key}`)
  }
}

function assertPlistValues(
  values: Record<string, unknown>,
  source: string,
): void {
  for (const [key, value] of Object.entries(values)) {
    if (value === null || value === undefined) {
      throw new Error(`${source}.${key} must be a plist value`)
    }
    if (Array.isArray(value)) {
      value.forEach((item, index) =>
        assertPlistValue(item, `${source}.${key}[${index}]`)
      )
    } else if (typeof value === 'object') {
      assertPlistValues(value as Record<string, unknown>, `${source}.${key}`)
    } else if (!['string', 'number', 'boolean'].includes(typeof value)) {
      throw new Error(`${source}.${key} must be a plist value`)
    }
  }
}

function assertPlistValue(value: unknown, source: string): void {
  if (value === null || value === undefined) {
    throw new Error(`${source} must be a plist value`)
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) =>
      assertPlistValue(item, `${source}[${index}]`)
    )
    return
  }
  if (typeof value === 'object') {
    assertPlistValues(value as Record<string, unknown>, source)
    return
  }
  if (!['string', 'number', 'boolean'].includes(typeof value)) {
    throw new Error(`${source} must be a plist value`)
  }
}

export function assertReleaseNamespacesDistinct(
  namespaces: { name: string; source: string }[],
): void {
  const seen = new Map<string, string>()
  for (const { name, source } of namespaces) {
    const owner = seen.get(name)
    if (owner !== undefined) {
      throw new Error(
        `release namespace ${name} is claimed by both ${owner} and ${source}`,
      )
    }
    seen.set(name, source)
  }
}

let apply = false
let generateAll = false
let generateUmbrella = false
let generateModule = false
let generateSchemes = false
let generateSwiftPM = false
let workspacePackage: string | undefined
let swiftPMPackages: string[] = []
let packageArgs: string[] = []
// --public-tree: generating the exported public repo (tools/public/export.ts
// writes the flag into that tree's generate tasks), which carries no internal
// packages such as view-pilot.
let publicTree = false

// `--workspace <dir>` is the only value-taking flag; everything else is a
// boolean, so a bare scan keeps the value out of the positional package list.
export function takeFlagValue(
  rawArgs: string[],
  flag: string,
): { value?: string; rest: string[] } {
  const rest: string[] = []
  let value: string | undefined
  for (let index = 0; index < rawArgs.length; index += 1) {
    const arg = rawArgs[index]
    if (arg === flag) {
      const next = rawArgs[index + 1]
      if (!next || next.startsWith('--')) {
        throw new Error(
          `${flag} needs a package directory, e.g. ${flag} packages/arcroom`,
        )
      }
      value = normalize(next.replace(/\/+$/, ''))
      index += 1
      continue
    }
    if (arg.startsWith(`${flag}=`)) {
      value = normalize(arg.slice(flag.length + 1).replace(/\/+$/, ''))
      continue
    }
    rest.push(arg)
  }
  return { value, rest }
}

function configure(rawArgs: string[]): void {
  const taken = takeFlagValue(rawArgs, '--workspace')
  workspacePackage = taken.value
  rawArgs = taken.rest
  const args = new Set(rawArgs)
  const knownFlags = new Set([
    '--apply',
    '--all',
    '--umbrella',
    '--module',
    '--apps',
    '--schemes',
    '--swiftpm',
    '--public-tree',
  ])
  const unknown = rawArgs.find((arg) =>
    arg.startsWith('--') && !knownFlags.has(arg)
  )
  if (unknown) throw new Error(`Unknown manifest option: ${unknown}`)
  apply = args.has('--apply')
  generateAll = args.has('--all')
  generateUmbrella = args.has('--umbrella')
  generateModule = args.has('--module')
  publicTree = args.has('--public-tree')
  // The Xcode app targets consume the same generated Info.plists the Bazel
  // shells do, so the workspace cannot be built without them.
  generateSchemes = args.has('--schemes')
  // Per-package Package.swift is editor ergonomics only: no Bazel target reads
  // it, and `swift build` against it resolves a different graph than Bazel
  // (upstream traits unpatched, versions unpinned). Xcode schemes need it.
  generateSwiftPM = args.has('--swiftpm') || generateSchemes
  packageArgs = rawArgs.filter((arg) => !arg.startsWith('--'))
}

async function readYaml<T>(path: string): Promise<T> {
  return parse(await Deno.readTextFile(path)) as T
}

// packageName is interpolated straight into `package_name = "..."`, so a
// missing one emits a target named after `undefined` instead of failing.
async function readPackageManifest(
  packageDir: string,
): Promise<PackageManifest> {
  const path = join(packageDir, 'package.yml')
  const pkg = await readYaml<PackageManifest>(path)
  assertOwner(pkg.owner, path)
  if (!pkg.packageName) {
    throw new Error(`${path} must declare packageName.`)
  }
  return pkg
}

async function exists(path: string): Promise<boolean> {
  try {
    await Deno.stat(path)
    return true
  } catch (error) {
    if (error instanceof Deno.errors.NotFound) return false
    throw error
  }
}

async function removeIfPresent(path: string): Promise<void> {
  try {
    await Deno.remove(path)
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error
  }
}

let signingTeamIDCache: string | undefined

async function signingTeamID(): Promise<string> {
  if (signingTeamIDCache !== undefined) return signingTeamIDCache
  const config = await readYaml<{ team?: string }>('tools/signing/signing.yml')
  if (!config.team || !teamIDPattern.test(config.team)) {
    throw new Error(
      'tools/signing/signing.yml team must be 10 characters of A-Z0-9',
    )
  }
  signingTeamIDCache = config.team
  return config.team
}

async function globFiles(pathspec: string): Promise<string[]> {
  const star = pathspec.indexOf('/*/')
  const suffix = star === -1 ? '' : pathspec.slice(star + 3)
  if (star === -1 || suffix.includes('*')) {
    throw new Error(`unsupported glob: ${pathspec}`)
  }
  const prefix = pathspec.slice(0, star)
  const matches: string[] = []
  for await (const entry of Deno.readDir(prefix)) {
    if (!entry.isDirectory) continue
    const candidate = join(prefix, entry.name, suffix)
    try {
      const stat = await Deno.stat(candidate)
      if (stat.isFile) matches.push(candidate)
    } catch (error) {
      if (!(error instanceof Deno.errors.NotFound)) throw error
    }
  }
  return matches.sort((lhs, rhs) => lhs.localeCompare(rhs))
}

const generatedOutputs = new Set<string>()

async function writeIfChanged(path: string, content: string): Promise<void> {
  generatedOutputs.add(path)
  try {
    if ((await Deno.readTextFile(path)) === content) {
      console.log(`unchanged ${path}`)
      return
    }
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error
  }
  await Deno.writeTextFile(path, content)
  console.log(`wrote ${path}`)
}

async function replaceFile(path: string, content: string): Promise<void> {
  const temporary = `${path}.${Deno.pid}.tmp`
  await Deno.writeTextFile(temporary, content)
  await Deno.rename(temporary, path)
}

async function discoverTargets(root: string): Promise<TargetManifest[]> {
  const targets: TargetManifest[] = []

  for (
    const manifestPath of await globFiles(`${root}/Targets/*/target.yml`)
  ) {
    const target = await readYaml<Omit<TargetManifest, 'manifestDir'>>(
      manifestPath,
    )
    const resolved = { ...target, manifestDir: dirname(manifestPath) }
    validateTargetRelease(resolved)
    validateTargetInfo(resolved)
    validateTargetLinkedFrameworks(resolved)
    targets.push(resolved)
  }

  return targets.sort((lhs, rhs) => lhs.name.localeCompare(rhs.name))
}

// SwiftPM derives a package identity from the last path component of its URL,
// lowercased with a trailing `.git` stripped ("Yams.git" -> "yams",
// "GRDB.swift.git" -> "grdb.swift"). This is the value SwiftPM writes into
// Package.resolved and the one `.product(package:)` must reference.
export function swiftPMIdentityFromUrl(url: string): string {
  const tail = url.split(/[\/]/).pop() ?? url
  // SSH URLs (`git@host:org/repo.git`) keep the repo after the final segment.
  const stripped = tail.replace(/\.git$/, '')
  return stripped.toLowerCase()
}

// rules_swift_package_manager (rspm) mints one Bazel repo per SwiftPM
// dependency as `swiftpkg_` + identity with `-` -> `_` (dots preserved), which
// is the name `use_repo(swift_deps, ...)` surfaces in MODULE.bazel.
export function bazelRepoFromUrl(url: string): string {
  return `swiftpkg_${swiftPMIdentityFromUrl(url).replace(/-/g, '_')}`
}

// A local path dependency lives under `packages/<dir>`; its Bazel package label
// is `//packages/<dir>`. Resolve the relative `path` against the consuming
// package directory to recover that label.
export function bazelPackageFromPath(packageDir: string, path: string): string {
  return `//${normalize(join(packageDir, path))}`
}

function declaresProduct(external: ExternalPackage, product: string): boolean {
  return Array.isArray(external.products)
    ? external.products.includes(product)
    : product in external.products
}

// Bazel target label backing a product. rspm exposes each SwiftPM product as a
// same-named target, and our own `wuhu_swift_library` emits `name = target.name`,
// so the list form maps a product to itself; the map form overrides that.
export function productTargetLabel(
  external: ExternalPackage,
  product: string,
): string {
  if (Array.isArray(external.products)) {
    if (!external.products.includes(product)) {
      throw new Error(`External package declares no product ${product}`)
    }
    return product
  }
  const target = external.products[product]
  if (!target) {
    throw new Error(`External package declares no product ${product}`)
  }
  return target
}

// The generator sees every package in one run, so a local path external that
// names a macro-kind target in its `products` list is detectable and rejected
// here: a macro is a compiler plugin consumed within its owning package, never a
// linkable product a sibling package can import. Left unchecked it lands in a
// consumer's Bazel `deps` (green only for swift_test/binary) and a dangling
// SwiftPM `.product(...)`, surfacing a package away from the real mistake.
export function assertNoMacroProductExport(
  external: ExternalPackage,
  macroTargetNames: Set<string>,
  locator: string,
): void {
  const productNames = Array.isArray(external.products)
    ? external.products
    : Object.keys(external.products)
  for (const product of productNames) {
    const label = productTargetLabel(external, product)
    if (macroTargetNames.has(label)) {
      throw new Error(
        `${locator} consumes macro target "${label}" as a product: macro targets are consumed within their owning package, not as products.`,
      )
    }
  }
}

function externalForProduct(
  pkg: PackageManifest,
  product: string,
): [string, ExternalPackage] {
  const matches = Object.entries(pkg.externalPackages ?? {}).filter(
    ([_, external]) => declaresProduct(external, product),
  )
  if (matches.length === 1) return matches[0]
  if (matches.length === 0) {
    throw new Error(`No external package declares product ${product}`)
  }
  throw new Error(
    `External product ${product} is ambiguous: ${
      matches.map(([identity]) => identity).join(', ')
    }`,
  )
}

// The SwiftPM identity for a local path dependency is the dependency package's
// own `name`, not the path and not a free-form label. Reading it ties the
// `.product(package:)` argument to the same source of truth SwiftPM resolves
// against, so the YAML map key cannot silently drift into a wrong identity.
async function localPackageIdentity(
  packageDir: string,
  path: string,
): Promise<string> {
  const targetDir = normalize(join(packageDir, path))
  const targetPkg = await readPackageManifest(targetDir)
  return targetPkg.name
}

function assertIdentityKey(
  key: string,
  identity: string,
  locator: string,
  packageDir: string,
): void {
  if (key !== identity) {
    throw new Error(
      `externalPackages key "${key}" in ${packageDir}/package.yml must match its SwiftPM identity "${identity}" (derived from ${locator}); the key is the package identity used by \`.product(package:)\`, not a display label.`,
    )
  }
}

// Populate the derived fields of each external: `identity` (always), and
// `bazelRepo` for remote / `bazelPackage` for local when the author has not
// supplied an override. Crashes early when a map key does not match the
// identity its locator implies, which would otherwise emit a `.product(package:)`
// that SwiftPM cannot resolve.
async function resolveExternalPackages(
  pkg: PackageManifest,
  packageDir: string,
): Promise<void> {
  await Promise.all(
    Object.entries(pkg.externalPackages ?? {}).map(
      async ([key, external]) => {
        if (external.url) {
          const identity = swiftPMIdentityFromUrl(external.url)
          assertIdentityKey(key, identity, external.url, packageDir)
          external.identity = identity
          external.bazelRepo ??= bazelRepoFromUrl(external.url)
        } else if (external.path) {
          const targetDir = normalize(join(packageDir, external.path))
          const identity = await localPackageIdentity(
            packageDir,
            external.path,
          )
          assertIdentityKey(key, identity, external.path, packageDir)
          external.identity = identity
          external.bazelPackage ??= bazelPackageFromPath(
            packageDir,
            external.path,
          )
          const producerTargets = await exists(join(targetDir, 'Targets'))
            ? await discoverTargets(targetDir)
            : []
          const macroTargetNames = new Set(
            producerTargets
              .filter((target) => target.kind === 'macro')
              .map((target) => target.name),
          )
          assertNoMacroProductExport(
            external,
            macroTargetNames,
            `${packageDir}/package.yml`,
          )
        } else {
          throw new Error(`External package ${key} has neither url nor path`)
        }
      },
    ),
  )
}

function dependencyName(dep: Dependency): string {
  if (typeof dep === 'string') return dep
  if ('swift' in dep) {
    throw new Error(
      `dependency ${
        JSON.stringify(dep.name)
      } uses the retired \`swift:\` toggle; a raw Bazel label declares a \`swiftpm:\` lowering (binaryTarget or cTarget) instead, so the dependency exists in both graphs`,
    )
  }
  if (dep.name) return dep.name
  throw new Error(`Invalid dependency ${JSON.stringify(dep)}`)
}

function bazelEnabled(dep: Dependency): boolean {
  return typeof dep === 'string' || dep.bazel !== false
}

function isRawLabel(name: string): boolean {
  return name.startsWith('@') || name.startsWith('//')
}

export function rawLabelLowering(dep: Dependency): SwiftPMLowering {
  const name = dependencyName(dep)
  const lowering = typeof dep === 'string' ? undefined : dep.swiftpm
  if (!lowering) {
    throw new Error(
      `raw Bazel label dependency ${
        JSON.stringify(name)
      } declares no swiftpm: lowering; give it a binaryTarget (hosted xcframework zip) or a cTarget (pinned source checkout) so the package stays buildable under SwiftPM`,
    )
  }
  const declared = [lowering.binaryTarget, lowering.cTarget]
    .filter((kind) => kind !== undefined)
  if (declared.length !== 1) {
    throw new Error(
      `raw Bazel label dependency ${
        JSON.stringify(name)
      } must declare exactly one of swiftpm.binaryTarget or swiftpm.cTarget`,
    )
  }
  return lowering
}

export function loweredTargetName(dep: Dependency): string {
  const lowering = rawLabelLowering(dep)
  if (lowering.cTarget) return lowering.cTarget.module
  const name = dependencyName(dep)
  const target = name.split(':').pop()
  if (!target) throw new Error(`cannot derive a target name from ${name}`)
  return target
}

function swiftDependency(
  pkg: PackageManifest,
  targetNames: Set<string>,
  dep: Dependency,
): string {
  const name = dependencyName(dep)
  if (isRawLabel(name)) return `"${loweredTargetName(dep)}"`
  if (targetNames.has(name)) return `"${name}"`
  const [, external] = externalForProduct(pkg, name)
  if (!external.identity) {
    throw new Error(`External package for ${name} was not resolved`)
  }
  return `.product(name: "${name}", package: "${external.identity}")`
}

function bazelDependency(
  pkg: PackageManifest,
  targetNames: Set<string>,
  dep: Dependency,
): string {
  const name = dependencyName(dep)
  if (targetNames.has(name)) return `":${name}"`
  // A raw Bazel label passes through, as it already does in app.yml. It names a
  // pinned `http_archive` repository such as `@ffmpeg//:libavcodec`; the
  // lowering it must carry (validated here so the error fires on every
  // generation, not only under --swiftpm) is what the SwiftPM emitter uses.
  if (isRawLabel(name)) {
    rawLabelLowering(dep)
    return `"${name}"`
  }
  const [, external] = externalForProduct(pkg, name)
  const target = productTargetLabel(external, name)
  if (external.bazelPackage) return `"${external.bazelPackage}:${target}"`
  if (!external.bazelRepo) {
    throw new Error(`External package for ${name} has no bazelRepo`)
  }
  return `"@${external.bazelRepo}//:${target}"`
}

// A sibling target of `kind: macro` is a compiler plugin: `swift_compiler_plugin`
// applies through `plugins = [...]`, not `deps = [...]`, on a consuming
// library/binary. So a dependency naming such a sibling is routed to the
// `plugins` bucket; everything else (external products, non-macro siblings) stays
// in `deps`. Tests are the exception (`macrosToDeps`): a test that must `import`
// the macro module for `assertMacroExpansion` needs it in `deps` (swift_test
// accepts a compiler-plugin target there), where plugins= would leave the module
// unimportable. The SwiftPM path needs no such split — SwiftPM carries a `.macro`
// dependency as an ordinary `dependencies:` entry.
export function partitionBazelDeps(
  pkg: PackageManifest,
  targetNames: Set<string>,
  kindByName: Map<string, TargetKind>,
  dependencies: Dependency[] | undefined,
  macrosToDeps = false,
): { deps: string[]; plugins: string[] } {
  const deps: string[] = []
  const plugins: string[] = []
  for (const dep of dependencies ?? []) {
    if (!bazelEnabled(dep)) continue
    const name = dependencyName(dep)
    const macroSibling = targetNames.has(name) &&
      kindByName.get(name) === 'macro'
    if (macroSibling && !macrosToDeps) {
      plugins.push(`":${name}"`)
    } else if (macroSibling) {
      deps.push(`":${name}"`)
    } else {
      deps.push(bazelDependency(pkg, targetNames, dep))
    }
  }
  return { deps, plugins }
}

function swiftPackageRequirement(external: ExternalPackage): string {
  const traits = external.traits?.length
    ? `, traits: [${external.traits.map((t) => `"${t}"`).join(', ')}]`
    : ''
  if (external.path) return `path: "${external.path}"${traits}`
  if (!external.url) throw new Error('External package has no url or path')
  if (external.exact) {
    return `url: "${external.url}", exact: "${external.exact}"${traits}`
  }
  if (external.from) {
    return `url: "${external.url}", from: "${external.from}"${traits}`
  }
  if (external.revision) {
    return `url: "${external.url}", revision: "${external.revision}"${traits}`
  }
  if (external.branch) {
    return `url: "${external.url}", branch: "${external.branch}"${traits}`
  }
  throw new Error(`External package ${external.url} has no requirement`)
}

function targetRelativePath(
  packageDir: string,
  target: TargetManifest,
  subpath: string,
): string {
  return relative(packageDir, join(target.manifestDir, subpath))
}

function swiftResources(resources: Resource[] | undefined): string {
  const lines = (resources ?? []).map((resource) => {
    const method = resource.mode === 'copy' ? 'copy' : 'process'
    return `        .${method}("${resource.path}")`
  })
  return lines.length
    ? `,\n      resources: [\n${lines.join(',\n')}\n      ]`
    : ''
}

function swiftSettingsExpr(settings: SwiftSetting[] | undefined): string {
  if (!settings?.length) return ''
  const entries = settings.map((s) => {
    if (s.enableExperimentalFeature) {
      return `.enableExperimentalFeature("${s.enableExperimentalFeature}")`
    }
    if (s.define) return `.define("${s.define}")`
    if (s.unsafeFlags) return `.unsafeFlags(${JSON.stringify(s.unsafeFlags)})`
    throw new Error('invalid swiftSetting')
  })
  return `,
      swiftSettings: [\n        ${entries.join(',\n        ')}\n      ]`
}

function swiftSettingsCoptsAttr(settings: SwiftSetting[] | undefined): string {
  const copts = swiftSettingsCopts(settings)
  return copts.length ? `    copts = ${quotedStarlarkList(copts)},\n` : ''
}

function swiftSettingsCopts(settings: SwiftSetting[] | undefined): string[] {
  const copts: string[] = []
  for (const s of settings ?? []) {
    if (s.enableExperimentalFeature) {
      copts.push('-enable-experimental-feature', s.enableExperimentalFeature)
    } else if (s.define) {
      copts.push('-D' + s.define)
    } else if (s.unsafeFlags) {
      copts.push(...s.unsafeFlags)
    } else {
      throw new Error('invalid swiftSetting')
    }
  }
  return copts
}

function targetCoptsAttr(
  target: TargetManifest,
  settings: SwiftSetting[] | undefined = target.swiftSettings,
): string {
  const settingsCopts = swiftSettingsCopts(settings)
  const terms = [
    ...(target.copts ?? []),
    ...(settingsCopts.length ? [quotedStarlarkList(settingsCopts)] : []),
  ]
  return terms.length ? `    copts = ${terms.join(' + ')},\n` : ''
}

const checkPlatforms: CheckPlatform[] = [
  'linux',
  'mac',
  'ios',
  'tvos',
  'visionos',
  'watchos',
]

// A simulator lane sets a simulator target platform, for which Bazel resolves no
// test toolchain: a `swift_test` cannot even be analyzed there. These lanes get
// a `swift_test`; the simulator lanes below get an `.xctest` bundle instead.
export const runnablePlatforms: CheckPlatform[] = ['linux', 'mac']

// Lanes whose tests lower to a rules_apple `*_unit_test` bundle, run by
// `//bazel/rules:<lane>_sim_test_runner` on a persistent simulator.
export const simulatorTestPlatforms: CheckPlatform[] = [
  'ios',
  'tvos',
  'visionos',
]

const simulatorPlatformFloorKeys: Record<string, string> = {
  ios: 'iOS',
  tvos: 'tvOS',
  visionos: 'visionOS',
}

// A library must compile wherever anything that depends on it is checked, so it
// claims the union of its build and test platforms. A dependent claiming more
// platforms than its dependency is a metadata bug that Bazel now reports as an
// analysis error naming both targets, instead of never being built at all.
function libraryPlatforms(
  pkg: PackageManifest,
  target: TargetManifest,
): CheckPlatform[] {
  const build = target.checks?.build ?? pkg.checks?.build ?? []
  const test = testTargets(target).flatMap(({ config }) =>
    declaredTestPlatforms(pkg, target, config)
  )
  return checkPlatforms.filter((platform) =>
    build.includes(platform) || test.includes(platform)
  )
}

function declaredTestPlatforms(
  pkg: PackageManifest,
  target: TargetManifest,
  test: TestConfig,
): CheckPlatform[] {
  return test.checks?.test ?? target.checks?.test ?? pkg.checks?.test ?? []
}

function testTargetPlatforms(
  pkg: PackageManifest,
  target: TargetManifest,
  test: TestConfig,
  location: string,
): CheckPlatform[] {
  const declared = declaredTestPlatforms(pkg, target, test)
  const unknown = declared.filter((platform) =>
    !checkPlatforms.includes(platform)
  )
  if (unknown.length > 0) {
    throw new Error(
      `${location} declares unknown check platforms: ${unknown.join(', ')}`,
    )
  }
  return declared.filter((platform) => runnablePlatforms.includes(platform))
}

// A simulator test bundle deploys at the package's floor for that platform;
// without one, rules_apple would pick its own default and the test would run
// against an OS the package never claims to support.
function simulatorTestLanes(
  pkg: PackageManifest,
  target: TargetManifest,
  test: TestConfig,
  location: string,
): {
  lane: CheckPlatform
  minimumOSVersion: string
}[] {
  const declared = declaredTestPlatforms(pkg, target, test)
  return declared
    .filter((platform) => simulatorTestPlatforms.includes(platform))
    .map((lane) => {
      const key = simulatorPlatformFloorKeys[lane]!
      const minimumOSVersion = pkg.platforms?.[key]
      if (!minimumOSVersion) {
        throw new Error(
          `${location} names ${lane} in checks.test, but the package declares no ${key} platform floor`,
        )
      }
      return { lane, minimumOSVersion }
    })
}

export async function targetCheckPlatforms(
  packageDir: string,
): Promise<Map<string, CheckPlatform[]>> {
  const pkg = await readPackageManifest(packageDir)
  const result = new Map<string, CheckPlatform[]>()
  for (const target of await discoverTargets(packageDir)) {
    if (target.kind === 'macro') continue
    const platforms = libraryPlatforms(pkg, target)
    result.set(target.name, platforms)
    if (target.kind === 'executable' && target.productName) {
      result.set(target.productName, platforms)
    }
    if (target.kind === 'systemLibrary' || target.kind === 'objcLibrary') {
      continue
    }
    for (const test of testTargets(target)) {
      const location = `${target.manifestDir}/target.yml`
      const hosts = testTargetPlatforms(pkg, target, test.config, location)
      if (hosts.length) result.set(test.name, hosts)
      for (
        const { lane } of simulatorTestLanes(pkg, target, test.config, location)
      ) {
        result.set(`${test.name}.${lane}`, [lane])
      }
    }
  }
  return result
}

function platformsAttr(
  platforms: CheckPlatform[],
  location: string,
): string {
  if (platforms.length === 0) {
    throw new Error(
      `${location} resolves to no check platforms; declare checks.build and/or checks.test`,
    )
  }
  const unknown = platforms.filter((platform) =>
    !checkPlatforms.includes(platform)
  )
  if (unknown.length > 0) {
    throw new Error(
      `${location} declares unknown check platforms: ${unknown.join(', ')}`,
    )
  }
  return `    target_compatible_with = wuhu_platforms(${
    quotedStarlarkList(platforms)
  }),\n`
}

function testSizeAttr(
  size: TestSize | undefined,
  location: string,
): string {
  if (size === undefined) return ''
  if (!testSizes.includes(size)) {
    throw new Error(
      `invalid test size ${
        JSON.stringify(size)
      } in ${location}: expected one of ${testSizes.join(', ')}`,
    )
  }
  return `    size = "${size}",\n`
}

function testTagsAttr(tags: string[] | undefined): string {
  return tags?.length ? `    tags = ${quotedStarlarkList(tags)},\n` : ''
}

function swiftTargetDecl(
  pkg: PackageManifest,
  packageDir: string,
  target: TargetManifest,
  targetNames: Set<string>,
): string {
  const deps = (target.dependencies ?? [])
    .map((dep) => `        ${swiftDependency(pkg, targetNames, dep)}`)
    .join(',\n')
  const factory = target.kind === 'macro'
    ? 'macro'
    : target.kind === 'executable'
    ? 'executableTarget'
    : 'target'
  const embeddedPaths = (target.embeddedResources ?? [])
    .map((resource) => resource.path)
    .filter((path): path is string => path !== undefined)
  const embeddedExcludes = embeddedPaths.length
    ? `,\n      exclude: [\n${
      embeddedPaths.map((path) => `        "${path}"`).join(',\n')
    }\n      ]`
    : ''
  return `    .${factory}(\n      name: "${target.name}",\n      dependencies: [${
    deps ? `\n${deps},\n      ` : ''
  }],\n      path: "${
    targetRelativePath(packageDir, target, target.sources)
  }"${embeddedExcludes}${swiftResources(target.resources)}${
    swiftSettingsExpr(target.swiftSettings)
  }${linkedFrameworksExpr(target.linkedFrameworks)}\n    )`
}

function linkedFrameworksExpr(frameworks: string[] | undefined): string {
  if (!frameworks?.length) return ''
  return `,\n      linkerSettings: [\n        ${
    frameworks.map((framework) => `.linkedFramework("${framework}")`).join(
      ',\n        ',
    )
  }\n      ]`
}

function linkedFrameworksLinkoptsAttr(
  frameworks: string[] | undefined,
): string {
  if (!frameworks?.length) return ''
  return `    linkopts = ${
    quotedStarlarkList(
      frameworks.flatMap((framework) => ['-framework', framework]),
    )
  },\n`
}

function systemLibraryDecl(packageDir: string, target: TargetManifest): string {
  const providers = target.apt?.length
    ? `,\n      providers: [.apt([${
      target.apt.map((pkg) => `"${pkg}"`).join(', ')
    }])]`
    : ''
  return `    .systemLibrary(\n      name: "${target.name}",\n      path: "${
    targetRelativePath(packageDir, target, '.')
  }"${providers}\n    )`
}

function swiftTestDecl(
  pkg: PackageManifest,
  packageDir: string,
  target: TargetManifest,
  test: ResolvedTestTarget,
  targetNames: Set<string>,
): string {
  const config = test.config
  const testDeps = [
    `.byName(name: "${target.name}")`,
    '.product(name: "IssueReportingTestSupport", package: "xctest-dynamic-overlay")',
    ...(config.dependencies ?? [])
      .map((dep) => swiftDependency(pkg, targetNames, dep)),
  ]
  const excludes = (config.exclude ?? []).length
    ? `,\n      exclude: [\n${
      config.exclude!.map((item) => `        "${item}"`).join(',\n')
    }\n      ]`
    : ''
  return `    .testTarget(\n      name: "${test.name}",\n      dependencies: [\n        ${
    testDeps.join(',\n        ')
  },\n      ],\n      path: "${
    targetRelativePath(packageDir, target, test.sources)
  }"${excludes}${swiftResources(config.resources)}${
    swiftSettingsExpr(config.swiftSettings)
  }\n    )`
}

export function productTargets(
  pkg: PackageManifest,
  targets: TargetManifest[],
): TargetManifest[] {
  const byName = new Map(targets.map((target) => [target.name, target]))
  const explicit = Array.isArray(pkg.products)
  const selected = explicit
    ? (pkg.products as string[]).map((name) => {
      const target = byName.get(name)
      if (!target) throw new Error(`Unknown product target ${name}`)
      return target
    })
    : targets
  // A macro target is a compiler plugin, not a linkable product. Naming one
  // explicitly in `products:` is a misconfiguration: crash rather than emit a
  // Package.swift that silently drops it and let the error surface a package
  // away. When `products` is unset or `all`, macros are excluded quietly below.
  if (explicit) {
    const macro = selected.find((target) => target.kind === 'macro')
    if (macro) {
      throw new Error(
        `Product "${macro.name}" is a macro target: macro targets are consumed within their owning package, not exported as products. Remove it from products:.`,
      )
    }
  }
  return selected.filter((target) => target.kind !== 'macro')
}

// One SwiftPM target per distinct lowered dependency, deduped across the
// package; two targets naming the same label with diverging configs is a
// manifest bug surfaced here rather than as a duplicate-target Package.swift.
export function collectLoweredDependencies(
  targets: TargetManifest[],
): Map<string, SwiftPMLowering> {
  const byName = new Map<string, SwiftPMLowering>()
  const deps = targets.flatMap((target) => [
    ...(target.dependencies ?? []),
    ...testTargets(target).flatMap(({ config }) => config.dependencies ?? []),
  ])
  for (const dep of deps) {
    const name = dependencyName(dep)
    if (!isRawLabel(name)) continue
    const lowering = rawLabelLowering(dep)
    const targetName = loweredTargetName(dep)
    const existing = byName.get(targetName)
    if (existing && JSON.stringify(existing) !== JSON.stringify(lowering)) {
      throw new Error(
        `conflicting swiftpm lowerings for ${targetName}: ${
          JSON.stringify(existing)
        } vs ${JSON.stringify(lowering)}`,
      )
    }
    byName.set(targetName, lowering)
  }
  return byName
}

export function upstreamCheckoutDir(module: string): string {
  return `.upstream/${module}`
}

function loweredTargetDecl(name: string, lowering: SwiftPMLowering): string {
  if (lowering.binaryTarget) {
    const { url, checksum } = lowering.binaryTarget
    return `    .binaryTarget(\n      name: "${name}",\n      url: "${url}",\n      checksum: "${checksum}"\n    )`
  }
  const c = lowering.cTarget!
  const sources = c.sources.map((source) => `"${source}"`).join(', ')
  const excluded = (c.exclude ?? []).map((path) => `"${path}"`).join(', ')
  const settings: string[] = [
    ...(c.defines ?? []).map((define) => `.define("${define}")`),
    ...(c.headerSearchPaths ?? []).map((path) =>
      `.headerSearchPath("${path}")`
    ),
  ]
  if (c.unsafeFlags?.length) {
    settings.push(`.unsafeFlags(${JSON.stringify(c.unsafeFlags)})`)
  }
  const cSettings = settings.length
    ? `,\n      cSettings: [\n        ${settings.join(',\n        ')}\n      ]`
    : ''
  const linked = (c.linuxLibraries ?? []).map((library) =>
    `.linkedLibrary("${library}", .when(platforms: [.linux]))`
  )
  const linkerSettings = linked.length
    ? `,\n      linkerSettings: [\n        ${
      linked.join(',\n        ')
    }\n      ]`
    : ''
  return `    .target(\n      name: "${name}",\n      path: "${
    upstreamCheckoutDir(c.module)
  }",\n${
    excluded ? `      exclude: [${excluded}],\n` : ''
  }      sources: [${sources}],\n      publicHeadersPath: "include"${cSettings}${linkerSettings}\n    )`
}

export function generatePackageSwift(
  pkg: PackageManifest,
  packageDir: string,
  targets: TargetManifest[],
): string {
  const targetNames = new Set(targets.map((target) => target.name))
  const platforms = Object.entries(pkg.platforms ?? {})
    .map(([platform, version]) => `    .${platform}("${version}")`)
    .join(',\n')

  const products = productTargets(pkg, targets)
    .map((target) => {
      const factory = target.kind === 'executable' ? 'executable' : 'library'
      return `    .${factory}(name: "${
        target.productName ?? target.name
      }", targets: ["${target.name}"])`
    })
    .join(',\n')

  const externals = targets.some((target) => testTargets(target).length > 0)
    ? testSupportPackages(pkg)
    : pkg.externalPackages ?? {}
  const dependencies = Object.entries(externals)
    .map(([_, external]) => {
      return `    .package(${swiftPackageRequirement(external)})`
    })
    .join(',\n')

  const targetDecls: string[] = []
  for (const target of targets) {
    if (target.kind === 'systemLibrary') {
      targetDecls.push(systemLibraryDecl(packageDir, target))
      continue
    }
    targetDecls.push(swiftTargetDecl(pkg, packageDir, target, targetNames))
    for (const test of testTargets(target)) {
      targetDecls.push(
        swiftTestDecl(pkg, packageDir, target, test, targetNames),
      )
    }
  }

  for (const [name, lowering] of collectLoweredDependencies(targets)) {
    targetDecls.push(loweredTargetDecl(name, lowering))
  }

  const defaultLocalization = pkg.defaultLocalization
    ? `\n  defaultLocalization: "${pkg.defaultLocalization}",`
    : ''

  const macroImport = targets.some((target) => target.kind === 'macro')
    ? '\nimport CompilerPluginSupport'
    : ''

  return `// swift-tools-version: ${pkg.swiftToolsVersion}\nimport PackageDescription${macroImport}\n\nlet package = Package(\n  name: "${pkg.name}",${defaultLocalization}\n  platforms: [\n${platforms}\n  ],\n  products: [\n${products}\n  ],\n  dependencies: [\n${dependencies}\n  ],\n  targets: [\n${
    targetDecls.join(',\n\n')
  }\n  ]\n)\n`
}

function starlarkList(items: string[], indent = '        '): string {
  if (!items.length) return '[]'
  return `[\n${items.map((item) => `${indent}${item},`).join('\n')}\n    ]`
}

function dirnameForResource(path: string): string {
  const index = path.lastIndexOf('/')
  return index === -1 ? '' : path.slice(0, index)
}

function basenameForResource(path: string): string {
  const index = path.lastIndexOf('/')
  return index === -1 ? path : path.slice(index + 1)
}

async function firstFileUnder(path: string): Promise<string | undefined> {
  const stat = await Deno.stat(path)
  if (stat.isFile) return ''

  const entries: string[] = []
  for await (const entry of Deno.readDir(path)) {
    const child = join(path, entry.name)
    if (entry.isFile) entries.push(entry.name)
    if (entry.isDirectory) {
      const nested = await firstFileUnder(child)
      if (nested) entries.push(`${entry.name}/${nested}`)
    }
  }
  entries.sort()
  return entries[0]
}

async function resourceSentinel(
  target: TargetManifest,
  sourceRoot: string,
  resources: Resource[],
): Promise<string> {
  for (
    const resource of [...resources].sort((lhs, rhs) =>
      lhs.path.localeCompare(rhs.path)
    )
  ) {
    const file = await firstFileUnder(
      join(target.manifestDir, target.sources, resource.path),
    )
    if (file !== undefined) {
      const basename = basenameForResource(resource.path)
      return file ? `${basename}/${file}` : basename
    }
  }
  throw new Error(
    `${target.name} has resources but no files under ${sourceRoot}`,
  )
}

async function bazelResourceExpr(
  target: TargetManifest,
  resources: Resource[],
  sourceRoot: string,
): Promise<string> {
  const globs: string[] = []
  const files: string[] = []
  for (const resource of resources) {
    const path = join(target.manifestDir, target.sources, resource.path)
    const stat = await Deno.stat(path)
    const labelPath = `${sourceRoot}/${resource.path}`
    if (stat.isDirectory) {
      globs.push(`"${labelPath}/**"`)
    } else if (stat.isFile) {
      files.push(`"${labelPath}"`)
    } else {
      throw new Error(`${path} is neither a file nor directory`)
    }
  }

  const chunks: string[] = []
  if (globs.length) chunks.push(`glob([${globs.join(', ')}])`)
  if (files.length) chunks.push(`[${files.join(', ')}]`)
  return chunks.join(' + ') || '[]'
}

async function bazelResourceAttrs(
  target: TargetManifest,
  sourceRoot: string,
  resources: Resource[] | undefined,
  sentinel: string | undefined,
): Promise<string> {
  if (!resources?.length) return ''
  if (!sentinel) {
    throw new Error(`Missing generated resource sentinel for ${sourceRoot}`)
  }
  const copy = resources.filter((resource) => resource.mode === 'copy')
  const process = resources.filter((resource) => resource.mode === 'process')
  const first = resources[0]
  const rootSuffix = dirnameForResource(first.path)
  const resourceRoot = rootSuffix ? `${sourceRoot}/${rootSuffix}` : sourceRoot
  const copyLine = copy.length
    ? `    copy_resources = ${await bazelResourceExpr(
      target,
      copy,
      sourceRoot,
    )},\n`
    : ''
  const processLine = process.length
    ? `    process_resources = ${await bazelResourceExpr(
      target,
      process,
      sourceRoot,
    )},\n`
    : ''
  return `${copyLine}${processLine}    resource_root = "${resourceRoot}",\n    resource_sentinel = "${sentinel}",\n`
}

function testDataAttr(
  data: string[] | undefined,
  externalData: string[] | undefined,
): string {
  const globs = data?.map((path) => `"${path}/**"`).join(', ')
  const parts = [
    globs ? `glob([${globs}])` : '',
    externalData?.length ? quotedStarlarkList(externalData) : '',
  ].filter(Boolean)
  if (!parts.length) return ''
  return `    extra_data = ${parts.join(' + ')},\n`
}

function testEnvAttr(env: Record<string, string> | undefined): string {
  const keys = Object.keys(env ?? {}).sort()
  if (!keys.length) return ''
  const entries = keys.map((key) => `"${key}": "${env![key]}"`).join(', ')
  return `    env = {${entries}},\n`
}

function bazelEmbeddedResourceAttrs(
  embeddedResources: EmbeddedResource[] | undefined,
  sourceRoot: string,
): string {
  if (!embeddedResources?.length) return ''
  const entries = embeddedResources.map((resource) => {
    const symbolName = resource.symbolName
      ? `,\n            "symbol_name": "${resource.symbolName}"`
      : ''
    const declared = [resource.path, resource.packagePath, resource.target]
      .filter((value) => value !== undefined)
    if (declared.length !== 1) {
      throw new Error(
        `Embedded resource ${resource.name} must declare exactly one of path, packagePath or target.`,
      )
    }
    if (resource.target) {
      return `        {
            "name": "${resource.name}",
            "directory": "${resource.target}",
            "type_name": "${resource.typeName}"${symbolName},
        }`
    }
    const resourceRoot = resource.packagePath ??
      `${sourceRoot}/${resource.path}`
    // A packagePath payload is authored elsewhere in the package and may legitimately
    // be absent (nothing seeded yet); an empty payload embeds as an empty section.
    const glob = resource.packagePath
      ? `glob(["${resourceRoot}/**"], allow_empty = True)`
      : `glob(["${resourceRoot}/**"])`
    return `        {
            "name": "${resource.name}",
            "srcs": ${glob},
            "strip_prefix": "${resourceRoot}",
            "type_name": "${resource.typeName}"${symbolName},
        }`
  })
  return `    embedded_directories = [\n${entries.join(',\n')}\n    ],\n`
}

function bazelSourceGlob(sourceRoot: string, excludes: string[] = []): string {
  if (!excludes.length) return `glob(["${sourceRoot}/**/*.swift"])`
  const excludePatterns = excludes.map((item) => `"${sourceRoot}/${item}"`)
    .join(', ')
  return `glob(["${sourceRoot}/**/*.swift"], exclude = [${excludePatterns}])`
}

// A stamped executable compiles a genrule-generated BuildStamp.swift fed by
// the workspace status files (see tools/workspace-status.sh and .bazelrc);
// WUHU_STAMPED compiles out the checked-in fallback, mirroring WUHU_EMBEDDED.
function stampGenrule(target: TargetManifest): string {
  return `genrule(
    name = "${target.name}_stamp",
    outs = ["Targets/${target.name}/BuildStamp.swift"],
    cmd = """
set -euo pipefail
version=$$(sed -n 's/^STABLE_WUHU_VERSION //p' bazel-out/stable-status.txt)
commit=$$(sed -n 's/^STABLE_WUHU_COMMIT //p' bazel-out/stable-status.txt)
date=$$(sed -n 's/^WUHU_BUILD_DATE //p' bazel-out/volatile-status.txt)
cat > $@ <<SWIFT
enum BuildStamp {
  static let version = "$\${version:?}"
  static let commit = "$\${commit:?}"
  static let date = "$\${date:?}"
}
SWIFT
""",
    stamp = 1,
)\n`
}

const infoPlistVersionPlaceholder = '@WUHU_VERSION@'

// macOS identifies a flat Mach-O by its code-signing identifier, which codesign
// takes from an embedded `__TEXT,__info_plist` section; without one the
// identifier is the file name and privacy grants (Local Network) do not survive
// a rebuild. The version keys come from the same status file as BuildStamp.
function infoPlistGenrule(target: TargetManifest): string {
  const plist = generatePlist({
    ...target.info!,
    CFBundleShortVersionString: infoPlistVersionPlaceholder,
    CFBundleVersion: infoPlistVersionPlaceholder,
  }).replaceAll('\\', '\\\\').replaceAll('$', '$$$$')
  return `genrule(
    name = "${target.name}_info_plist",
    outs = ["Targets/${target.name}/Info.plist"],
    cmd = """
set -euo pipefail
version=$$(sed -n 's/^STABLE_WUHU_VERSION //p' bazel-out/stable-status.txt)
sed "s/${infoPlistVersionPlaceholder}/$\${version:?}/g" > $@ <<'PLIST'
${plist}PLIST
""",
    stamp = 1,
    target_compatible_with = wuhu_platforms(["mac"]),
)\n`
}

function infoPlistLinkAttrs(target: TargetManifest): string {
  const plist = `:${target.name}_info_plist`
  const onMac = (items: string) =>
    `select({\n        "//bazel/constraints:mac": [${items}],\n        "//conditions:default": [],\n    })`
  return `    additional_linker_inputs = ${
    onMac(`"${plist}"`)
  },\n    linkopts = ${
    onMac(`"-Wl,-sectcreate,__TEXT,__info_plist,$(location ${plist})"`)
  },\n`
}

export async function generateBuildBazel(
  pkg: PackageManifest,
  targets: TargetManifest[],
): Promise<string> {
  const targetNames = new Set(targets.map((target) => target.name))
  const kindByName = new Map(
    targets.map((target) => [target.name, target.kind]),
  )
  const doccCatalogs = new Map<string, string>()
  for (const target of targets) {
    const sourceDirectory = join(target.manifestDir, target.sources)
    let catalogs: string[] = []
    try {
      catalogs = (await Array.fromAsync(Deno.readDir(sourceDirectory)))
        .filter((entry) => entry.isDirectory && entry.name.endsWith('.docc'))
        .map((entry) => entry.name)
        .sort()
    } catch (error) {
      if (!(error instanceof Deno.errors.NotFound)) throw error
    }
    if (catalogs.length > 1) {
      throw new Error(
        `${sourceDirectory} contains multiple .docc catalogs: ${
          catalogs.join(', ')
        }`,
      )
    }
    if (catalogs.length === 1) {
      if (target.kind === 'systemLibrary' || target.kind === 'objcLibrary') {
        throw new Error(
          `${sourceDirectory}/${catalogs[0]} cannot document a ${target.kind}`,
        )
      }
      doccCatalogs.set(
        target.name,
        `Targets/${target.name}/${target.sources}/${catalogs[0]}`,
      )
    }
  }
  if (doccCatalogs.size > 0 && targetNames.has('docs')) {
    throw new Error(
      'generated DocC site target :docs conflicts with a source target',
    )
  }
  const loadSymbols = [
    'wuhu_platforms',
    'wuhu_swift_binary',
    'wuhu_swift_library',
    'wuhu_swift_test',
  ]
  if (doccCatalogs.size > 0) {
    loadSymbols.push('wuhu_docc_archive', 'wuhu_docc_site')
  }
  if (targets.some((target) => target.kind === 'macro')) {
    loadSymbols.push('wuhu_swift_macro')
  }
  const targetCoptsSymbols = [
    ...new Set(targets.flatMap((target) => target.copts ?? [])),
  ]
  for (const symbol of targetCoptsSymbols) {
    if (!/^[A-Z][A-Z0-9_]*$/.test(symbol)) {
      throw new Error(`target copts entry is not a rules.bzl symbol: ${symbol}`)
    }
  }
  loadSymbols.push(...targetCoptsSymbols)
  if (
    targets.some((target) =>
      testTargets(target).some(({ config }) =>
        simulatorTestLanes(
          pkg,
          target,
          config,
          `${target.manifestDir}/target.yml`,
        ).length > 0
      )
    )
  ) {
    loadSymbols.push('wuhu_sim_test')
  }
  if (targets.some((target) => target.kind === 'systemLibrary')) {
    loadSymbols.push('wuhu_system_library')
  }
  if (targets.some((target) => target.openapiGenerate)) {
    loadSymbols.push('wuhu_openapi_sources')
  }
  const chunks = [
    `load("//bazel/rules:rules.bzl", ${
      loadSymbols.map((symbol) => `"${symbol}"`).join(', ')
    })`,
    `\npackage(default_visibility = ["//visibility:public"])\n`,
    // Release tooling reads these manifests as test inputs, and a source file
    // is only a label once the package exports it.
    `exports_files([\n${
      [
        'package.yml',
        ...targets.map((target) => `Targets/${target.name}/target.yml`),
      ].map((path) => `    "${path}",\n`).join('')
    }])\n`,
    // Every file of the package as one label, for a test that checks a path
    // into the package exists (//tools:public-links-test: the public docs'
    // links into packages/).
    `filegroup(\n    name = "files",\n    srcs = glob(["**"], exclude = ["BUILD.bazel"]),\n)\n`,
  ]

  if (targets.some((target) => target.kind === 'objcLibrary')) {
    chunks.unshift(
      'load("@rules_cc//cc:objc_library.bzl", "objc_library")',
    )
  }

  for (const target of targets) {
    if (target.kind === 'systemLibrary') {
      const root = `Targets/${target.name}`
      chunks.push(
        `wuhu_system_library(\n    name = "${target.name}",\n    hdrs = glob(["${root}/**/*.h"]),\n    module_map = "${root}/module.modulemap",\n    linkopts = ${
          quotedStarlarkList((target.link ?? []).map((lib) => `-l${lib}`))
        },\n${
          platformsAttr(
            libraryPlatforms(pkg, target),
            `${target.manifestDir}/target.yml`,
          )
        })\n`,
      )
      continue
    }
    if (target.kind === 'objcLibrary') {
      const root = `Targets/${target.name}/${target.sources}`
      const { deps } = partitionBazelDeps(
        pkg,
        targetNames,
        kindByName,
        target.dependencies,
      )
      chunks.push(
        `objc_library(\n    name = "${target.name}",\n    srcs = glob(["${root}/**/*.c", "${root}/**/*.m"], allow_empty = True),\n    hdrs = glob(["${root}/**/*.h"], allow_empty = True),\n    alwayslink = True,\n${
          deps.length ? `    deps = ${starlarkList(deps)},\n` : ''
        }${
          platformsAttr(
            libraryPlatforms(pkg, target),
            `${target.manifestDir}/target.yml`,
          )
        })\n`,
      )
      continue
    }
    const { deps, plugins } = partitionBazelDeps(
      pkg,
      targetNames,
      kindByName,
      target.dependencies,
    )
    const pluginsAttr = plugins.length
      ? `    plugins = ${starlarkList(plugins)},\n`
      : ''
    const sourceRoot = `Targets/${target.name}/${target.sources}`
    // Macros are host tools built in the exec configuration; a target-platform
    // constraint would be wrong here, not merely redundant.
    if (target.kind === 'macro') {
      chunks.push(
        `wuhu_swift_macro(\n    name = "${target.name}",\n    srcs = ${
          bazelSourceGlob(sourceRoot)
        },\n${swiftSettingsCoptsAttr(target.swiftSettings)}    deps = ${
          starlarkList(deps)
        },\n${pluginsAttr})\n`,
      )
    } else if (target.kind === 'executable') {
      if (target.stamp) chunks.push(stampGenrule(target))
      if (target.info) chunks.push(infoPlistGenrule(target))
      const srcs = target.stamp
        ? `${bazelSourceGlob(sourceRoot)} + [":${target.name}_stamp"]`
        : bazelSourceGlob(sourceRoot)
      const settings = target.stamp
        ? [...(target.swiftSettings ?? []), { define: 'WUHU_STAMPED' }]
        : target.swiftSettings
      chunks.push(
        `wuhu_swift_binary(\n    name = "${target.name}",\n    srcs = ${srcs},\n${
          swiftSettingsCoptsAttr(settings)
        }    deps = ${starlarkList(deps)},\n${pluginsAttr}${
          target.info ? infoPlistLinkAttrs(target) : ''
        }${
          platformsAttr(
            libraryPlatforms(pkg, target),
            `${target.manifestDir}/target.yml`,
          )
        })\n`,
      )
      if (target.productName && target.productName !== target.name) {
        chunks.push(
          `alias(\n    name = "${target.productName}",\n    actual = ":${target.name}",\n)\n`,
        )
      }
    } else {
      const sentinel = target.resources?.length
        ? await resourceSentinel(target, sourceRoot, target.resources)
        : undefined
      // When a target's sources are OpenAPI-generated, emit the producing rule
      // and feed its declared output as `srcs` instead of globbing `Sources/`
      // (which is gitignored and materialized only by the manual escape hatch).
      const openapi = target.openapiGenerate
      if (openapi) {
        chunks.push(
          `wuhu_openapi_sources(\n    name = "${target.name}_gen",\n    document = ":${openapi.document}",\n    config = ":Targets/${target.name}/${openapi.config}",\n    output = "${openapi.output}",\n)\n\n`,
        )
      }
      const librarySrcs = openapi
        ? starlarkList([`":${target.name}_gen"`])
        : bazelSourceGlob(sourceRoot)
      chunks.push(
        `wuhu_swift_library(\n    name = "${target.name}",\n    srcs = ${librarySrcs},\n${await bazelResourceAttrs(
          target,
          sourceRoot,
          target.resources,
          sentinel,
        )}${
          bazelEmbeddedResourceAttrs(
            target.embeddedResources,
            sourceRoot,
          )
        }${
          // Embedded payloads exist only in the Bazel graph; the define lets
          // sources fall back cleanly when SwiftPM compiles without them.
          targetCoptsAttr(
            target,
            target.embeddedResources?.length
              ? [...(target.swiftSettings ?? []), { define: 'WUHU_EMBEDDED' }]
              : target.swiftSettings,
          )}${
          linkedFrameworksLinkoptsAttr(target.linkedFrameworks)
        }    deps = ${starlarkList(deps)},
${pluginsAttr}    package_name = "${pkg.packageName}",
${
          platformsAttr(
            libraryPlatforms(pkg, target),
            `${target.manifestDir}/target.yml`,
          )
        })\n`,
      )
    }

    for (const test of testTargets(target)) {
      const config = test.config
      const testRoot = `Targets/${target.name}/${test.sources}`
      const { deps: testExtraDeps, plugins: testPlugins } = partitionBazelDeps(
        pkg,
        targetNames,
        kindByName,
        config.dependencies,
        true,
      )
      const testDeps = [
        `":${target.name}"`,
        '"@swiftpkg_xctest_dynamic_overlay//:IssueReportingTestSupport"',
        ...testExtraDeps,
      ]
      const testPluginsAttr = testPlugins.length
        ? `    plugins = ${starlarkList(testPlugins)},\n`
        : ''
      const testSentinel = config.resources?.length
        ? await resourceSentinel(
          { ...target, sources: test.sources },
          testRoot,
          config.resources,
        )
        : undefined
      const location = `${target.manifestDir}/target.yml`
      const sharedAttrs = `    srcs = ${
        bazelSourceGlob(testRoot, config.exclude)
      },\n${testSizeAttr(config.size, location)}${await bazelResourceAttrs(
        { ...target, sources: test.sources },
        testRoot,
        config.resources,
        testSentinel,
      )}${testDataAttr(config.data, config.externalData)}${
        testEnvAttr(config.env)
      }${
        config.envInherit?.length
          ? `    env_inherit = ${quotedStarlarkList(config.envInherit)},\n`
          : ''
      }${swiftSettingsCoptsAttr(config.swiftSettings)}    deps = ${
        starlarkList(testDeps)
      },\n${testPluginsAttr}`
      const runnable = testTargetPlatforms(pkg, target, config, location)
      const simulatorLanes = simulatorTestLanes(
        pkg,
        target,
        config,
        location,
      )
      if (runnable.length === 0 && simulatorLanes.length === 0) {
        throw new Error(
          `${location} declares tests but no checks.test platforms`,
        )
      }
      const strayHosts = Object.keys(config.host ?? {}).filter((lane) =>
        !simulatorLanes.some((simulator) => simulator.lane === lane)
      )
      if (strayHosts.length > 0) {
        throw new Error(
          `${location} names a test host for ${
            strayHosts.join(', ')
          }, which is not one of its simulator test lanes`,
        )
      }
      if (runnable.length > 0) {
        chunks.push(
          `wuhu_swift_test(\n    name = "${test.name}",\n    package_name = "${pkg.packageName}",\n${sharedAttrs}${
            testTagsAttr(config.tags)
          }${platformsAttr(runnable, location)})\n`,
        )
      }
      for (const { lane, minimumOSVersion } of simulatorLanes) {
        chunks.push(
          `wuhu_sim_test(\n    name = "${test.name}.${lane}",\n    lane = "${lane}",\n    module_name = "${test.name}",\n    package_name = "${pkg.packageName}",\n    minimum_os_version = "${minimumOSVersion}",\n${
            config.host?.[lane]
              ? `    test_host = "${config.host[lane]}",\n`
              : ''
          }${sharedAttrs}${
            config.tags?.length
              ? testTagsAttr([
                'resources:simulators:1',
                ...config.tags,
              ])
              : `    tags = ["resources:simulators:1"],\n`
          }${platformsAttr([lane], location)})\n`,
        )
      }
    }
  }

  if (doccCatalogs.size > 0) {
    const targetsByName = new Map(
      targets.map((target) => [target.name, target]),
    )
    const dependenciesFor = (target: TargetManifest): string[] => {
      const found = new Set<string>()
      const visit = (candidate: TargetManifest) => {
        for (const dependency of candidate.dependencies ?? []) {
          if (!bazelEnabled(dependency)) continue
          const name = dependencyName(dependency)
          const local = targetsByName.get(name)
          if (!local || !doccCatalogs.has(name) || found.has(name)) continue
          found.add(name)
          visit(local)
        }
      }
      visit(target)
      return [...found].sort()
    }

    for (const target of targets) {
      const catalog = doccCatalogs.get(target.name)
      if (!catalog) continue
      const dependencies = dependenciesFor(target)
      chunks.push(
        `wuhu_docc_archive(
    name = "${target.name}DocC",
    target = ":${target.name}",
    module_name = "${target.name}",
    catalog_path = "${catalog}",
    catalog = glob(["${catalog}/**"]),
${
          dependencies.length
            ? `    dependencies = ${
              starlarkList(
                dependencies.map((name) => `":${name}DocC"`),
              )
            },
`
            : ''
        }    target_compatible_with = wuhu_platforms(["mac"]),
    tags = ["manual"],
)
`,
      )
    }
    chunks.push(
      `wuhu_docc_site(
    name = "docs",
    archives = ${
        starlarkList(
          [...doccCatalogs.keys()].sort().map((name) => `":${name}DocC"`),
        )
      },
    landing_page_name = "${pkg.packageName}",
    target_compatible_with = wuhu_platforms(["mac"]),
    tags = ["manual"],
)
`,
    )
  }

  return chunks.join('\n')
}

export async function discoverPackageDirs(root: string): Promise<string[]> {
  return (await globFiles(`${root}/*/package.yml`))
    .map((manifestPath) => manifestPath.slice(0, -'/package.yml'.length))
    .sort()
}

interface DenoPackageManifest {
  owner?: string
  tasks?: Record<string, string>
  generated?: Record<string, string>
  exportedDirs?: Record<string, string>
}

// Two levels, because a deno workspace root is itself a directory under
// packages/ whose members are nested inside it (deno requires physical
// nesting). A manifest that declares `workspace` is a root, not a package: it
// contributes the cluster's shared files and is not built on its own.
export async function discoverDenoPackageDirs(root: string): Promise<string[]> {
  const topLevel = await globFiles(`${root}/*/deno.json`)
  const nested: string[] = []
  for (const manifestPath of topLevel) {
    const dir = manifestPath.slice(0, -'/deno.json'.length)
    nested.push(...await globFiles(`${dir}/*/deno.json`))
  }
  // `deno install` materializes workspace members as node_modules symlinks;
  // discovering those would generate a second BUILD file per member.
  const visible = (path: string) => !path.includes('/node_modules/')
  const dirs = [...topLevel, ...nested].filter(visible).map((manifestPath) =>
    manifestPath.slice(0, -'/deno.json'.length)
  )
  const packages: string[] = []
  for (const dir of dirs) {
    if (await readDenoWorkspace(join(dir, 'deno.json')) === undefined) {
      packages.push(dir)
    }
  }
  return packages.sort()
}

// A workspace root is not a package: it exists so members can label its shared
// deno.json/deno.lock. The repo root already exports its own.
function denoWorkspaceRootDirs(
  workspaces: Map<string, DenoWorkspaceRoot>,
): string[] {
  const dirs = new Set<string>()
  for (const workspace of workspaces.values()) {
    if (workspace.dir) dirs.add(workspace.dir)
  }
  return [...dirs].sort()
}

// Directories Bazel must never traverse, enumerated per package because
// .bazelignore has no glob support. Two classes: `deno install` links workspace
// members into node_modules, and those symlinks point back at real Bazel
// packages — so `//...` would discover every member a second time, at a second
// label, and build it. And per-package SwiftPM litter (`.build` checkouts can
// hold self-referential symlinks that blow up glob traversal, `Packages` is
// edit-mode checkouts, `.upstream` is the cTarget-lowering fetch dir).
export function bazelIgnore(
  denoDirs: string[],
  swiftPackageDirs: string[],
): string {
  const entries = [
    ...denoDirs.map((dir) => `${dir}/node_modules`),
    ...swiftPackageDirs.flatMap((dir) => [
      `${dir}/.build`,
      `${dir}/.upstream`,
      `${dir}/Packages`,
    ]),
  ]
  return [...new Set(entries)].sort().map((entry) => `${entry}\n`).join('')
}

function denoWorkspaceRootBuildBazel(): string {
  return 'exports_files([\n    "deno.json",\n    "deno.lock",\n])\n'
}

// Maps every workspace member to its owning root, so a member can be handed the
// right deno.json/deno.lock instead of the repo root's.
export async function discoverDenoWorkspaces(
  root: string,
): Promise<Map<string, DenoWorkspaceRoot>> {
  const byMember = new Map<string, DenoWorkspaceRoot>()
  const candidates = [
    'deno.json',
    ...await globFiles(`${root}/*/deno.json`),
  ]
  for (const manifestPath of candidates) {
    const workspace = await readDenoWorkspace(manifestPath)
    if (!workspace) continue
    const rootDir = manifestPath === 'deno.json'
      ? ''
      : manifestPath.slice(0, -'/deno.json'.length)
    const members = workspace.members.map((member) =>
      rootDir ? join(rootDir, member) : member
    )
    // `links` are relative to the workspace root and normally point outside it.
    const links = workspace.links.map((link) =>
      normalize(rootDir ? join(rootDir, link) : link)
    )
    for (const member of members) {
      byMember.set(member, { dir: rootDir, members, links })
    }
  }
  return byMember
}

function denoSrcsGlob(extraExcludes: string[]): string {
  const excludes = [
    '.env*',
    '.react-router/**',
    'BUILD.bazel',
    'build/**',
    'node_modules/**',
    '**/.DS_Store',
    ...extraExcludes,
  ]
  const lines = excludes.map((pattern) =>
    `            ${JSON.stringify(pattern)},`
  ).join('\n')
  return `glob(\n        ["**"],\n        exclude = [\n${lines}\n        ],\n    )`
}

function denoGeneratedAttr(generated: Record<string, string>): string {
  const entries = Object.entries(generated).sort(([lhs], [rhs]) =>
    lhs.localeCompare(rhs)
  )
  if (entries.length === 0) return ''
  const lines = entries
    .map(([dest, target]) =>
      `        ${JSON.stringify(target)}: ${JSON.stringify(dest)},`
    )
    .join('\n')
  return `    generated = {\n${lines}\n    },\n`
}

export interface DenoWorkspace {
  members: string[]
  links: string[]
}

export interface DenoWorkspaceRoot {
  // Repo-relative workspace root directory; '' is the repo root.
  dir: string
  members: string[]
  // Repo-relative directories of `links` targets declared by that root.
  links: string[]
}

// A workspace member shares its own root's deno.json/deno.lock and every
// sibling member's tree, since Bazel globs cannot cross package boundaries. It
// exposes its own files as a `:srcs` filegroup that siblings pull in by label,
// and the deno rules materialize the whole cluster in the sandbox before running
// the task from the member's directory. The root is whichever deno.json declares
// this member — not necessarily the repo root.
function denoWorkspaceAttrs(
  packageDir: string,
  workspace: DenoWorkspaceRoot,
): string {
  const prefix = workspace.dir ? `//${workspace.dir}:` : '//:'
  const rootFiles = ['deno.json', 'deno.lock'].map((file) =>
    JSON.stringify(`${prefix}${file}`)
  )
  let attrs = `    workspace_root_files = ${starlarkList(rootFiles)},\n`
  const siblings = workspace.members
    .filter((member) => member !== packageDir)
    .map((member) => JSON.stringify(`//${member}:srcs`))
  if (siblings.length) {
    attrs += `    workspace_member_srcs = ${starlarkList(siblings)},\n`
  }
  const links = workspace.links.map((link) => JSON.stringify(`//${link}:srcs`))
  if (links.length) {
    attrs += `    link_srcs = ${starlarkList(links)},\n`
  }
  return attrs
}

// A deno package is one atomic Bazel target per workspace (repo-layout law 4):
// a `bundle` tree output when the manifest declares a `build` task, plus one
// test per checking task. All key on sources + deno.lock + the pinned toolchain.
export function generateDenoBuildBazel(
  packageDir: string,
  manifest: DenoPackageManifest,
  workspace?: DenoWorkspaceRoot,
): string {
  assertOwner(manifest.owner, `${packageDir}/deno.json`)
  const tasks = manifest.tasks ?? {}
  const generated = manifest.generated ?? {}
  const isMember = workspace !== undefined
  const srcsGlob = denoSrcsGlob(Object.keys(generated).sort())
  const srcs = `[":srcs"]`
  const generatedAttr = denoGeneratedAttr(generated)
  const workspaceAttr = isMember
    ? denoWorkspaceAttrs(packageDir, workspace!)
    : ''
  // Deno tasks are host tooling; the simulator lanes have no business running
  // them, and without this every lane would.
  const denoPlatformsAttr = platformsAttr(
    ['linux', 'mac'],
    `${packageDir}/deno.json`,
  )
  const symbols: string[] = []
  const chunks: string[] = [
    `filegroup(\n    name = "srcs",\n    srcs = ${srcsGlob},\n)\n`,
  ]
  if (tasks.build) {
    symbols.push('deno_bundle')
    chunks.push(
      `deno_bundle(\n    name = "bundle",\n    srcs = ${srcs},\n${generatedAttr}${workspaceAttr}    output_dir = "build/client",\n    tags = ["requires-network"],\n${denoPlatformsAttr})\n`,
    )
  }
  for (const task of ['fmt', 'typecheck', 'lint', 'test']) {
    if (!tasks[task]) continue
    if (!symbols.includes('deno_task_test')) symbols.push('deno_task_test')
    chunks.push(
      `deno_task_test(\n    name = "${task}",\n    srcs = ${srcs},\n${generatedAttr}${workspaceAttr}    tags = ["requires-network"],\n    task = "${task}",\n${denoPlatformsAttr})\n`,
    )
  }
  for (
    const [name, dir] of Object.entries(manifest.exportedDirs ?? {})
      .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
  ) {
    if (!symbols.includes('exported_dir')) symbols.push('exported_dir')
    chunks.push(
      `exported_dir(\n    name = ${JSON.stringify(name)},\n    srcs = glob([${
        JSON.stringify(`${dir}/**`)
      }], exclude = ["**/.DS_Store"]),\n    path = ${
        JSON.stringify(dir)
      },\n)\n`,
    )
  }
  if (!chunks.length) {
    throw new Error(
      `${packageDir}/deno.json declares none of build/typecheck/lint tasks; nothing to generate.`,
    )
  }
  return [
    `load("//bazel/rules:deno.bzl", ${
      symbols.map((symbol) => `"${symbol}"`).join(', ')
    })`,
    `load("//bazel/rules:rules.bzl", "wuhu_platforms")`,
    `\npackage(default_visibility = ["//visibility:public"])\n`,
    ...chunks,
  ].join('\n')
}

export async function readDenoWorkspace(
  root = 'deno.json',
): Promise<DenoWorkspace | undefined> {
  const manifest = JSON.parse(await Deno.readTextFile(root)) as {
    workspace?: string[]
    links?: string[]
  }
  if (!manifest.workspace?.length) return undefined
  return {
    members: manifest.workspace
      .map((member) => normalize(member).replace(/^\.\//, ''))
      .sort(),
    links: (manifest.links ?? []).map((link) => normalize(link)).sort(),
  }
}

async function generateDenoPackage(
  packageDir: string,
  workspace?: DenoWorkspaceRoot,
): Promise<void> {
  const manifest = JSON.parse(
    await Deno.readTextFile(join(packageDir, 'deno.json')),
  ) as DenoPackageManifest
  const buildOutput = join(
    packageDir,
    apply ? 'BUILD.bazel' : 'BUILD.generated.bazel',
  )
  await writeIfChanged(
    buildOutput,
    generateDenoBuildBazel(packageDir, manifest, workspace),
  )
}

function dependencyIdentityFields(external: ExternalPackage): string {
  return JSON.stringify({
    url: external.url,
    exact: external.exact,
    from: external.from,
    revision: external.revision,
    branch: external.branch,
    traits: external.traits ? [...external.traits].sort() : undefined,
  })
}

// The umbrella exists only to resolve external dependencies, so its floor must
// satisfy the strictest package in the repo — the highest declared version wins.
// A package's own deployment target stays its own business: nothing forces two
// products shipping to different OS floors to agree.
export function comparePlatformVersions(lhs: string, rhs: string): number {
  const parse = (version: string) =>
    version.split('.').map((part) => Number.parseInt(part, 10))
  const left = parse(lhs)
  const right = parse(rhs)
  if (left.some(Number.isNaN) || right.some(Number.isNaN)) {
    throw new Error(`unparsable platform version: ${lhs} vs ${rhs}`)
  }
  for (let index = 0; index < Math.max(left.length, right.length); index += 1) {
    const diff = (left[index] ?? 0) - (right[index] ?? 0)
    if (diff !== 0) return diff
  }
  return 0
}

function platformOrder(platform: string): number {
  const order = ['macOS', 'iOS', 'visionOS', 'tvOS', 'watchOS']
  const index = order.indexOf(platform)
  return index === -1 ? order.length : index
}

// rules_swift_package_manager resolves fetched revisions from the tracked
// bazel/umbrella/Package.resolved, not from the generated umbrella manifest,
// so a package.yml pin bump without a lockfile re-resolve silently keeps
// building the old revision (#939, #1355).
export function assertLockfileHonorsPins(
  externals: Map<string, ExternalPackage>,
  lockfileJson: string,
): void {
  const lockfile = JSON.parse(lockfileJson) as {
    pins?: {
      identity?: string
      state?: { revision?: string; version?: string }
    }[]
  }
  const pins = new Map(
    (lockfile.pins ?? []).map((pin) => [pin.identity ?? '', pin.state ?? {}]),
  )
  const fix =
    'run `swift package --package-path bazel/umbrella resolve` and commit bazel/umbrella/Package.resolved'
  for (const [identity, external] of externals) {
    if (external.path) continue
    const requirement = external.revision
      ? { field: 'revision' as const, want: external.revision }
      : external.exact
      ? { field: 'version' as const, want: external.exact }
      : undefined
    if (!requirement) continue
    const pin = pins.get(identity)
    if (!pin) {
      throw new Error(
        `bazel/umbrella/Package.resolved has no pin for ${identity}; ${fix}`,
      )
    }
    if (pin[requirement.field] !== requirement.want) {
      throw new Error(
        `bazel/umbrella/Package.resolved pins ${identity} at ${requirement.field} ${
          pin[requirement.field]
        }, but package.yml requires ${requirement.want}. Bazel builds the lockfile's revision, so without a re-resolve this pin change is a silent no-op; ${fix}.`,
      )
    }
  }
}

async function generateUmbrellaPackageSwift(
  packageDirs: string[],
): Promise<string> {
  const packages = await Promise.all(
    packageDirs.map(async (packageDir) => {
      const pkg = await readPackageManifest(packageDir)
      await resolveExternalPackages(pkg, packageDir)
      return pkg
    }),
  )

  const platforms = new Map<string, string>()
  const externals = new Map<string, ExternalPackage>()

  for (const pkg of packages) {
    collectPackageMetadata(pkg, platforms, externals)
  }

  assertLockfileHonorsPins(
    externals,
    await Deno.readTextFile('bazel/umbrella/Package.resolved'),
  )

  const platformDecls = [...platforms.entries()]
    .sort(([lhs], [rhs]) =>
      platformOrder(lhs) - platformOrder(rhs) || lhs.localeCompare(rhs)
    )
    .map(([platform, version]) => `    .${platform}("${version}")`)
    .join(',\n')

  const dependencyDecls = [...externals.entries()]
    .sort(([lhs], [rhs]) => lhs.localeCompare(rhs))
    .map(([_, external]) =>
      `    .package(${swiftPackageRequirement(external)})`
    )
    .join(',\n')

  return `// swift-tools-version: 6.2
// Generated by deno task generate-manifests. Do not edit.
import PackageDescription

let package = Package(
  name: "Umbrella",
  platforms: [
${platformDecls}
  ],
  dependencies: [
${dependencyDecls}
  ]
)
`
}

function collectPackageMetadata(
  pkg: PackageManifest,
  platforms: Map<string, string>,
  externals: Map<string, ExternalPackage>,
): void {
  for (const [platform, version] of Object.entries(pkg.platforms ?? {})) {
    const existing = platforms.get(platform)
    if (
      existing === undefined || comparePlatformVersions(version, existing) > 0
    ) {
      platforms.set(platform, version)
    }
  }

  for (const external of Object.values(testSupportPackages(pkg))) {
    if (external.path) continue
    const identity = external.identity
    if (!identity) {
      throw new Error(
        `External package in ${pkg.name} was not resolved before umbrella collection`,
      )
    }
    const existing = externals.get(identity)
    if (existing) {
      const existingFields = dependencyIdentityFields(existing)
      const newFields = dependencyIdentityFields(external)
      if (existingFields !== newFields) {
        throw new Error(
          `Conflicting external package requirement for ${identity}: ${existingFields} vs ${newFields}`,
        )
      }
      continue
    }
    externals.set(identity, external)
  }
}

async function generateModuleBazel(packageDirs: string[]): Promise<string> {
  const packages = await Promise.all(
    packageDirs.map(async (packageDir) => {
      const pkg = await readPackageManifest(packageDir)
      await resolveExternalPackages(pkg, packageDir)
      return pkg
    }),
  )

  const externals = new Map<string, ExternalPackage>()
  for (const pkg of packages) {
    collectPackageMetadata(pkg, new Map(), externals)
  }

  const repos = [
    'swift_package',
    ...[...externals.values()]
      .map((external) => external.bazelRepo)
      .filter((repo): repo is string => repo !== undefined)
      .sort((lhs, rhs) => lhs.localeCompare(rhs)),
  ]
  return renderModuleBazel({
    template: await Deno.readTextFile('MODULE.bazel.template'),
    swiftDepsRepos: repos,
    packageModules: await readPackageModules(packageDirs),
    configure: await readConfigureFragments(),
    pinned: pinnedRepos(
      await Deno.readTextFile('bazel/umbrella/Package.resolved'),
    ),
    strict: true,
  })
}

function schemeXml(target: TargetManifest): string {
  const name = target.name
  const tests = testTargets(target)
  const testables = tests.length
    ? `
      <Testables>
${
      tests.map((test) =>
        `         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "${test.name}"
               BuildableName = "${test.name}"
               BlueprintName = "${test.name}"
               ReferencedContainer = "container:">
            </BuildableReference>
         </TestableReference>`
      ).join('\n')
    }
      </Testables>`
    : ''
  return `<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2640"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "${name}"
               BuildableName = "${name}"
               BlueprintName = "${name}"
               ReferencedContainer = "container:">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">${testables}
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <MacroExpansion>
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "${name}"
            BuildableName = "${name}"
            BlueprintName = "${name}"
            ReferencedContainer = "container:">
         </BuildableReference>
      </MacroExpansion>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
`
}

async function generateSchemesForPackage(
  packageDir: string,
  targets: TargetManifest[],
): Promise<void> {
  const schemesDir = join(
    packageDir,
    '.swiftpm/xcode/xcshareddata/xcschemes',
  )
  await Deno.mkdir(schemesDir, { recursive: true })
  for (const target of targets) {
    await writeIfChanged(
      join(schemesDir, `${target.name}.xcscheme`),
      schemeXml(target),
    )
  }
}

// PackageDescription's `.macro` factory has no `resources:` parameter, and the
// Bazel plugin rule silently drops resource attributes, so the two build systems
// would diverge on an invalid field combination. Reject it at generation time.
function assertNoMacroResources(targets: TargetManifest[]): void {
  for (const target of targets) {
    if (target.kind !== 'macro') continue
    if (target.resources?.length) {
      throw new Error(
        `Macro target "${target.name}" declares resources:, unsupported by PackageDescription's .macro factory. Remove them from the macro target.`,
      )
    }
    if (target.embeddedResources?.length) {
      throw new Error(
        `Macro target "${target.name}" declares embeddedResources:, unsupported by macro targets. Remove them from the macro target.`,
      )
    }
  }
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    bytes as unknown as ArrayBuffer,
  )
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('')
}

// Materializes the pinned upstream a cTarget lowering compiles, into an
// untracked, Bazel-ignored checkout the generated Package.swift points at.
// Idempotent: a marker recording the archive sha256 skips the refetch, and any
// other state is torn down and rebuilt.
async function ensureUpstreamCheckout(
  packageDir: string,
  c: CTargetLowering,
): Promise<void> {
  const dir = join(packageDir, upstreamCheckoutDir(c.module))
  const marker = join(dir, '.fetched-sha256')
  try {
    if ((await Deno.readTextFile(marker)).trim() === c.fetch.sha256) return
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error
  }
  try {
    await Deno.remove(dir, { recursive: true })
  } catch (error) {
    if (!(error instanceof Deno.errors.NotFound)) throw error
  }

  const response = await fetch(c.fetch.url)
  if (!response.ok) {
    throw new Error(`fetching ${c.fetch.url} failed: HTTP ${response.status}`)
  }
  const bytes = new Uint8Array(await response.arrayBuffer())
  const digest = await sha256Hex(bytes)
  if (digest !== c.fetch.sha256) {
    throw new Error(
      `sha256 mismatch for ${c.fetch.url}: expected ${c.fetch.sha256}, got ${digest}`,
    )
  }

  await Deno.mkdir(dir, { recursive: true })
  const archive = join(dir, '.archive.tar.gz')
  await Deno.writeFile(archive, bytes)
  const strip = c.fetch.stripPrefix ? ['--strip-components', '1'] : []
  const tar = await new Deno.Command('tar', {
    args: ['-xzf', archive, '-C', dir, ...strip],
    stderr: 'piped',
  }).output()
  if (!tar.success) {
    throw new Error(
      `extracting ${archive} failed: ${new TextDecoder().decode(tar.stderr)}`,
    )
  }
  await Deno.remove(archive)
  await Deno.mkdir(join(dir, 'include'), { recursive: true })
  if (requiresPublicHeaderMaterialization(c.publicHeader)) {
    await Deno.copyFile(
      join(dir, c.publicHeader),
      join(dir, 'include', c.publicHeader),
    )
  }
  await Deno.writeTextFile(marker, `${c.fetch.sha256}\n`)
  console.log(`fetched ${dir}`)
}

export function requiresPublicHeaderMaterialization(
  publicHeader: string,
): boolean {
  return !normalize(publicHeader).startsWith('include/')
}

// Two shells in one package can load the same rule file with different symbol
// sets — one with an extension rule, one without — and Bazel rejects a file
// loaded twice, so the symbols merge rather than the lines deduplicating.
export function mergeLoads(lines: readonly string[]): string[] {
  const symbolsByFile = new Map<string, Set<string>>()
  const opaque = new Set<string>()
  for (const line of lines) {
    const match = /^load\("([^"]+)", ((?:"[^"]+"(?:, )?)+)\)$/.exec(line)
    if (!match) {
      opaque.add(line)
      continue
    }
    const symbols = symbolsByFile.get(match[1]!) ?? new Set<string>()
    for (const symbol of match[2]!.split(', ')) symbols.add(symbol)
    symbolsByFile.set(match[1]!, symbols)
  }
  return [
    ...opaque,
    ...[...symbolsByFile].map(([file, symbols]) =>
      `load("${file}", ${[...symbols].sort().join(', ')})`
    ),
  ].sort()
}

export function combineBuildBazel(
  parts: readonly string[],
  releaseSources: readonly string[],
): string {
  const loads = mergeLoads(
    parts.flatMap((part) =>
      part.split('\n').filter((line) => line.startsWith('load('))
    ),
  )
  const bodies = parts.map((part) =>
    part.split('\n').filter((line) =>
      !line.startsWith('load(') &&
      line.trim() !== 'package(default_visibility = ["//visibility:public"])'
    ).join('\n').trim()
  ).filter((body) => body.length > 0)
  const releaseManifest = releaseSources.length === 0
    ? ''
    : `filegroup(\n    name = "release_manifest",\n    srcs = [\n${
      [...new Set(releaseSources)].sort().map((source) =>
        `        ${JSON.stringify(source)},\n`
      ).join('')
    }    ],\n)\n`
  return `${
    loads.join('\n')
  }\n\npackage(default_visibility = ["//visibility:public"])\n\n${
    [...bodies, releaseManifest].filter((body) => body.length > 0).join('\n\n')
  }\n`
}

async function generatePackage(packageDir: string): Promise<void> {
  const pkg = await readPackageManifest(packageDir)
  await resolveExternalPackages(pkg, packageDir)
  const targets = await discoverTargets(packageDir)
  assertNoMacroResources(targets)
  const appDirs = await discoverAppDirs(packageDir)
  const teamID = await appSigningTeamID(appDirs, signingTeamID)
  const apps = await Promise.all(
    appDirs.map((appDir) => prepareApp(appDir, packageDir, teamID)),
  )
  assertNoViewPilotDependency(
    packageDir,
    targets,
    apps.map((entry) => entry.app),
    await cachedViewPilotProducts(),
  )
  const platformsByIdentifier = profilePlatforms(apps.map((entry) => entry.app))
  const appBuilds = apps.map((entry) =>
    generateAppBuildBazel(
      entry.app,
      entry.entitlementSources,
      entry.pathPrefix,
      false,
      platformsByIdentifier,
    )
  )
  const releaseSources = apps.flatMap((entry) => [
    shellPath(entry.pathPrefix, 'app.yml'),
    ...entry.entitlementSources.map((source) =>
      shellPath(entry.pathPrefix, source)
    ),
  ])
  const buildBazel = combineBuildBazel(
    [await generateBuildBazel(pkg, targets), ...appBuilds],
    releaseSources,
  )

  const packageOutput = join(
    packageDir,
    apply ? 'Package.swift' : 'Package.generated.swift',
  )
  const buildOutput = join(
    packageDir,
    apply ? 'BUILD.bazel' : 'BUILD.generated.bazel',
  )
  if (generateSwiftPM || swiftPMPackages.includes(packageDir)) {
    for (const lowering of collectLoweredDependencies(targets).values()) {
      if (lowering.cTarget) {
        await ensureUpstreamCheckout(packageDir, lowering.cTarget)
      }
    }
    await writeIfChanged(
      packageOutput,
      generatePackageSwift(pkg, packageDir, targets),
    )
  } else if (await exists(packageOutput)) {
    // A stale manifest left behind keeps `swift build` working, which is the
    // affordance this flag exists to remove.
    await Deno.remove(packageOutput)
  }
  await writeIfChanged(buildOutput, buildBazel)
  if (generateSchemes) {
    await generateSchemesForPackage(packageDir, targets)
  }
}

function appRule(platform: AppBundleManifest['platform']): string {
  switch (platform) {
    case 'macOS':
      return 'macos_application'
    case 'iOS':
      return 'ios_application'
    case 'tvOS':
      return 'tvos_application'
    case 'visionOS':
      return 'visionos_application'
    case 'watchOS':
      return 'watchos_application'
  }
}

function extensionRule(platform: AppBundleManifest['platform']): string {
  switch (platform) {
    case 'macOS':
      return 'macos_extension'
    case 'iOS':
      return 'ios_extension'
    case 'tvOS':
      return 'tvos_extension'
    case 'visionOS':
      return 'visionos_extension'
    case 'watchOS':
      throw new Error('watchOS extensions are not app shell extensions')
  }
}

function appLoad(
  platform: AppBundleManifest['platform'],
  includeExtension: boolean,
): string {
  const symbols = includeExtension
    ? `"${appRule(platform)}", "${extensionRule(platform)}"`
    : `"${appRule(platform)}"`
  switch (platform) {
    case 'macOS':
      return `load("@build_bazel_rules_apple//apple:macos.bzl", ${symbols})`
    case 'iOS':
      return `load("@build_bazel_rules_apple//apple:ios.bzl", ${symbols})`
    case 'tvOS':
      return `load("@build_bazel_rules_apple//apple:tvos.bzl", ${symbols})`
    case 'visionOS':
      return `load("@build_bazel_rules_apple//apple:visionos.bzl", ${symbols})`
    case 'watchOS':
      return `load("@build_bazel_rules_apple//apple:watchos.bzl", ${symbols})`
  }
}

function quotedStarlarkList(items: string[], indent = '        '): string {
  return starlarkList(items.map((item) => JSON.stringify(item)), indent)
}

function appIconExpr(patterns: string[]): string {
  if (!patterns.length) return '[]'
  return `glob(${quotedStarlarkList(patterns)})`
}

function appResourcePatterns(paths: string[]): string[] {
  return paths.flatMap((path) => [path, `${path}/**`])
}

export type SigningVariant = 'dev' | 'adhoc' | 'store'

export function isPreviewBundle(bundle: { bundleID: string }): boolean {
  return bundle.bundleID.startsWith('tech.lakeridge.previews.')
}

// The bundle as one signing variant builds it: dev and adhoc take its
// devIdentity, store keeps the declared identity.
export function variantBundle<T extends AppBundleManifest>(
  target: T,
  variant: SigningVariant,
): T {
  const identity = target.devIdentity
  if (identity === undefined || variant === 'store') return target
  return {
    ...target,
    bundleID: identity.bundleID,
    displayName: identity.displayName ?? target.displayName,
    appIcons: identity.appIcons ?? target.appIcons,
    entitlements: {
      ...target.entitlements,
      common: { ...target.entitlements.common, ...identity.entitlements },
    },
    info: { ...target.info, ...identity.info },
    devIdentity: undefined,
  }
}

export function appEmbedsViewPilot(app: AppManifest): boolean {
  return app.targets.some(isPreviewBundle) || app.viewPilot !== false
}

export function bundleEmbedsViewPilot(
  app: AppManifest,
  target: AppBundleManifest,
): boolean {
  return app.targets.some((candidate) => candidate.name === target.name) &&
    appEmbedsViewPilot(app)
}

export const viewPilotPackage = 'packages/view-pilot'

let viewPilotProductsCache: string[] | null = null

// Only an app shell signs, so a package without shells reads no signing
// identity: the public tree carries none.
export async function appSigningTeamID(
  appDirs: readonly string[],
  teamID: () => Promise<string>,
): Promise<string> {
  return appDirs.length ? await teamID() : ''
}

// The public tree carries no view-pilot and so has nothing to guard; anywhere
// else a missing view-pilot manifest is an error.
export async function viewPilotProducts(
  packageDir: string,
  inPublicTree: boolean,
): Promise<string[]> {
  if (inPublicTree && !await exists(join(packageDir, 'package.yml'))) {
    return []
  }
  const products = (await readPackageManifest(packageDir)).products
  return products === 'all' || products === undefined ? [] : products
}

async function cachedViewPilotProducts(): Promise<string[]> {
  viewPilotProductsCache ??= await viewPilotProducts(
    viewPilotPackage,
    publicTree,
  )
  return viewPilotProductsCache
}

function namesViewPilot(dep: Dependency, products: readonly string[]): boolean {
  const name = dependencyName(dep)
  return name.startsWith(`//${viewPilotPackage}:`) || products.includes(name)
}

// ViewPilot is a development-only remote-control surface. The generator lowers
// it into embedding app shells behind `//bazel/signing:dev` and nowhere else, so
// a hand-written dependency on it — in a library that a release shell links, or
// in a shell that opted out — would ship it unconditionally. Refuse to emit that
// graph rather than audit it afterwards.
export function assertNoViewPilotDependency(
  packageDir: string,
  targets: readonly TargetManifest[],
  apps: readonly AppManifest[],
  products: readonly string[],
): void {
  if (packageDir === viewPilotPackage) return
  const refuse = (owner: string): never => {
    throw new Error(
      `${owner} declares a dependency on ViewPilot. ViewPilot is development-only: the generator injects it into app shells that embed it, under //bazel/signing:dev, and no other target may name it.`,
    )
  }
  for (const target of targets) {
    const suites = [
      target.dependencies,
      ...(target.tests === false || target.tests === undefined
        ? []
        : [target.tests.dependencies]),
      ...(target.additionalTestTargets ?? []).map((suite) =>
        suite.dependencies
      ),
    ]
    for (const dependencies of suites) {
      for (const dep of dependencies ?? []) {
        if (namesViewPilot(dep, products)) {
          refuse(`${packageDir} target ${target.name}`)
        }
      }
    }
  }
  for (const app of apps) {
    if (appEmbedsViewPilot(app)) continue
    for (const bundle of appBundles(app)) {
      for (const dep of bundle.dependencies ?? []) {
        if (namesViewPilot(dep, products)) {
          refuse(`${packageDir} app bundle ${bundle.name}`)
        }
      }
    }
  }
}

export function appBundles(app: AppManifest): AppBundleManifest[] {
  return [
    ...app.targets,
    ...(app.extensions ?? []),
    ...(app.watchApplications ?? []),
  ]
}

function shellPath(prefix: string, path: string): string {
  return prefix.length === 0 ? path : `${prefix}/${path}`
}

// adhoc shares the store file unless a devIdentity gives it its own identity.
export function entitlementPath(
  target: AppBundleManifest,
  variant: SigningVariant,
): string {
  const file = variant === 'dev'
    ? 'dev'
    : variant === 'adhoc' && target.devIdentity !== undefined
    ? 'adhoc'
    : 'release'
  return `${target.name}-${file}.entitlements`
}

// Each entitlements file the bundle's variants select, with the first variant
// that selects it; variants sharing a file resolve to the same entitlements.
export function entitlementSourcesByVariant(
  app: AppManifest,
  target: AppBundleManifest,
): Map<string, SigningVariant> {
  const sources = new Map<string, SigningVariant>()
  for (const variant of variantsFor(app, target)) {
    const path = entitlementPath(target, variant)
    if (!sources.has(path)) sources.set(path, variant)
  }
  return sources
}

function siblingPlistPath(path: string, variant: string): string {
  const suffix = '.plist'
  return path.endsWith(suffix)
    ? `${path.slice(0, -suffix.length)}-${variant}${suffix}`
    : `${path}-${variant}.plist`
}

export function releaseInfoPlistPath(path: string): string {
  return siblingPlistPath(path, 'release')
}

// The dev plist is the one app.yml names and carries the ViewPilot keys; store
// and, with a devIdentity, adhoc get `-release` and `-adhoc` siblings whenever
// their content differs from it.
export function infoPlistPaths(
  target: AppBundleManifest,
  embedsViewPilot: boolean,
): Record<SigningVariant, string> {
  const dev = target.infoPlist
  const store = embedsViewPilot || target.devIdentity !== undefined
    ? releaseInfoPlistPath(dev)
    : dev
  const adhoc = target.devIdentity === undefined
    ? store
    : embedsViewPilot
    ? siblingPlistPath(dev, 'adhoc')
    : dev
  return { dev, adhoc, store }
}

function profileName(
  target: AppBundleManifest,
  variant: SigningVariant,
  platformsByIdentifier: ReadonlyMap<string, ReadonlySet<string>>,
): string | undefined {
  if (isPreviewBundle(target)) {
    if (target.platform !== 'iOS') return undefined
    return variant === 'dev' ? 'Wuhu Dev Previews' : 'Wuhu AdHoc Previews'
  }
  // A macOS development bundle needs MAC_APP_DEVELOPMENT when it claims
  // restricted entitlements. Direct distribution would be MAC_APP_DIRECT,
  // which this repo does not ship.
  if (target.platform === 'macOS' && variant === 'adhoc') return undefined
  const label = variant === 'dev'
    ? 'Dev'
    : variant === 'adhoc'
    ? 'AdHoc'
    : 'Store'
  const identifier = variantBundle(target, variant).bundleID
  const platforms = platformsByIdentifier.get(identifier)
  const suffix = (platforms?.size ?? 0) > 1 ||
      target.platform === 'visionOS' || target.platform === 'watchOS'
    ? ` ${target.platform}`
    : ''
  return `Wuhu ${label} ${identifier}${suffix}`
}

export function appProfileName(
  app: AppManifest,
  target: AppBundleManifest,
  variant: SigningVariant,
): string | undefined {
  return profileName(target, variant, profilePlatforms([app]))
}

export function referencedProfileNames(
  apps: readonly AppManifest[],
): string[] {
  const platformsByIdentifier = profilePlatforms(apps)
  return apps.flatMap((app) =>
    appBundles(app).flatMap((target) =>
      variantsFor(app, target).map((variant) =>
        profileName(target, variant, platformsByIdentifier)
      )
    )
  ).filter((name) => name !== undefined)
}

function profileTargetName(
  target: AppBundleManifest,
  variant: SigningVariant,
): string {
  return `${target.name}_${variant}_profile__run_deno_task_prepare_profiles`
}

// An iOS preview builds adhoc on the wildcard AdHoc profile so it can be
// published as a try link; no preview ever builds store.
function variantsFor(
  _app: AppManifest,
  target: AppBundleManifest,
): SigningVariant[] {
  if (!isPreviewBundle(target)) return ['dev', 'adhoc', 'store']
  return target.platform === 'iOS' ? ['dev', 'adhoc'] : ['dev']
}

function selectExpr(
  entries: [string, string | null][],
  render: (value: string) => string = (value) => JSON.stringify(value),
): string {
  return `select({\n${
    entries.map(([condition, value]) =>
      `        "//bazel/signing:${condition}": ${
        value === null ? 'None' : render(value)
      },\n`
    ).join('')
  }    })`
}

// One value when every variant agrees, a select over the variants otherwise.
function variantExpr(
  values: Record<SigningVariant, string>,
  render: (value: string) => string,
  renderInSelect: (value: string) => string = render,
): string {
  const entries = Object.entries(values) as [SigningVariant, string][]
  return entries.every(([_, value]) => value === values.dev)
    ? render(values.dev)
    : selectExpr(entries, renderInSelect)
}

function perVariant<T>(
  map: (variant: SigningVariant) => T,
): Record<SigningVariant, T> {
  return { dev: map('dev'), adhoc: map('adhoc'), store: map('store') }
}

function generateAppBundleRule(
  app: AppManifest,
  target: AppBundleManifest,
  rule: string,
  manifestName: string,
  pathPrefix: string,
  platformsByIdentifier: ReadonlyMap<string, ReadonlySet<string>>,
  extensions: string[] = [],
  embedsViewPilot = false,
  watchApplication?: string,
): string {
  const variants = variantsFor(app, target)
  const profiles = variants.flatMap(
    (variant): [string, string | null][] => {
      const name = profileName(target, variant, platformsByIdentifier)
      if (name === undefined) return [[variant, null]]
      const profile = `:${profileTargetName(target, variant)}`
      return target.platform === 'macOS'
        ? [[variant, profile]]
        : [[`${variant}_simulator`, null], [variant, profile]]
    },
  )
  const entitlements = variants.map((variant): [string, string] => [
    variant,
    shellPath(pathPrefix, entitlementPath(target, variant)),
  ])
  const bundles = perVariant((variant) => variantBundle(target, variant))
  const icons = perVariant((variant) =>
    JSON.stringify(
      bundles[variant].appIcons.map((path) => shellPath(pathPrefix, path)),
    )
  )
  const plists = infoPlistPaths(target, embedsViewPilot)
  return `${rule}(\n    name = "${target.name}",\n    bundle_id = ${
    variantExpr(
      perVariant((variant) => bundles[variant].bundleID),
      (value) => JSON.stringify(value),
    )
  },\n    bundle_name = "${target.bundleName}",\n    families = ${
    quotedStarlarkList(target.families)
  },\n    entitlements = ${selectExpr(entitlements)},\n    app_icons = ${
    variantExpr(
      icons,
      (value) => appIconExpr(JSON.parse(value)),
      (value) => JSON.parse(value).length ? `glob(${value})` : '[]',
    )
  },\n${
    target.resources?.length
      ? `    resources = glob(${
        quotedStarlarkList(
          appResourcePatterns(
            target.resources.map((path) => shellPath(pathPrefix, path)),
          ),
        )
      }, allow_empty = True),\n`
      : ''
  }    infoplists = ${
    variantExpr(
      plists,
      (path) => `["${shellPath(pathPrefix, path)}"]`,
    )
  },\n    minimum_os_version = "${target.minimumOSVersion}",\n${
    profiles.some(([_, value]) => value !== null)
      ? `    provisioning_profile = ${selectExpr(profiles)},\n`
      : ''
  }${
    target.frameworks?.length
      ? `    frameworks = ${quotedStarlarkList(target.frameworks)},\n`
      : ''
  }${
    target.linkopts?.length
      ? `    linkopts = ${quotedStarlarkList(target.linkopts)},\n`
      : ''
  }${
    extensions.length
      ? `    extensions = ${quotedStarlarkList(extensions)},\n`
      : ''
  }${
    watchApplication
      ? `    watch_application = ${JSON.stringify(`:${watchApplication}`)},\n`
      : ''
  }${
    target.appIntents?.length
      ? `    app_intents = ${quotedStarlarkList(target.appIntents)},\n`
      : ''
  }    deps = ${quotedStarlarkList(target.dependencies)}${
    embedsViewPilot
      ? ` + select({\n        "//bazel/signing:dev": [\n            "//packages/view-pilot:ViewPilot",\n            "//packages/view-pilot:ViewPilotBootstrap",\n        ],\n        "//conditions:default": [],\n    })`
      : ''
  },\n${
    platformsAttr(
      [appTargetPlatform(target)],
      `${manifestName} ${shellPath(pathPrefix, 'app.yml')}`,
    )
  })\n`
}

const appPlatformChecks: Record<string, CheckPlatform> = {
  macOS: 'mac',
  iOS: 'ios',
  tvOS: 'tvos',
  visionOS: 'visionos',
  watchOS: 'watchos',
}

function appTargetPlatform(target: AppBundleManifest): CheckPlatform {
  const platform = appPlatformChecks[target.platform]
  if (!platform) {
    throw new Error(`unknown app target platform: ${target.platform}`)
  }
  return platform
}

// A shell library compiles exactly where the bundle targets that depend on it ship:
// the iOS-only labs use UIKit-only API absent on macOS, and the wuhu shell keeps
// a macOS-only library beside a mobile one. Deriving this per library — rather
// than per app — is what lets these targets drop `tags = ["manual"]` and be built
// by a plain `//...` on each lane.
function appLibrarySources(library: AppLibraryManifest): string[] {
  const sources = typeof library.sources === 'string'
    ? [library.sources]
    : library.sources
  if (sources.length === 0) {
    throw new Error(`app library ${library.name} declares no sources`)
  }
  return sources
}

// Reachability is transitive: a shell may layer libraries (Arcroom's tvOS shell
// takes the shared route resolver without any of the SwiftUI screens), so a
// library ships wherever any app target reaches it, not just where one names it.
function appLibraryPlatforms(
  app: AppManifest,
  library: AppLibraryManifest,
): CheckPlatform[] {
  const byName = new Map(
    (app.libraries ?? []).map((entry) => [entry.name, entry]),
  )
  const platforms = appBundles(app)
    .filter((target) =>
      reachesLibrary(target.dependencies, library.name, byName)
    )
    .map(appTargetPlatform)
  if (platforms.length === 0) {
    throw new Error(
      `${app.name} app.yml: library ${library.name} is not reachable from any app target`,
    )
  }
  return checkPlatforms.filter((platform) => platforms.includes(platform))
}

function reachesLibrary(
  dependencies: string[],
  name: string,
  byName: Map<string, AppLibraryManifest>,
): boolean {
  const seen = new Set<string>()
  const queue = dependencies.filter((dependency) => dependency.startsWith(':'))
  while (queue.length > 0) {
    const current = queue.pop()!.slice(1)
    if (current === name) return true
    if (seen.has(current)) continue
    seen.add(current)
    for (const dependency of byName.get(current)?.dependencies ?? []) {
      if (dependency.startsWith(':')) queue.push(dependency)
    }
  }
  return false
}

function profilePlatforms(
  apps: readonly AppManifest[],
): Map<string, ReadonlySet<string>> {
  const result = new Map<string, Set<string>>()
  for (const app of apps) {
    for (const target of appBundles(app)) {
      if (isPreviewBundle(target)) continue
      for (const variant of variantsFor(app, target)) {
        const identifier = variantBundle(target, variant).bundleID
        const platforms = result.get(identifier) ?? new Set<string>()
        platforms.add(target.platform)
        result.set(identifier, platforms)
      }
    }
  }
  return result
}

export function generateAppBuildBazel(
  app: AppManifest,
  entitlementSources: readonly string[] = [
    ...appBundles(app),
  ].flatMap((target) => [...entitlementSourcesByVariant(app, target).keys()]),
  pathPrefix = '',
  emitReleaseManifest = true,
  platformsByIdentifier: ReadonlyMap<string, ReadonlySet<string>> =
    profilePlatforms([app]),
): string {
  const embedsViewPilot = appEmbedsViewPilot(app)
  const coptsSymbols = [
    ...new Set([
      'WUHU_SWIFT_LANGUAGE_MODE_COPTS',
      ...(embedsViewPilot ? ['WUHU_UI_CONTROL_COPTS'] : []),
      ...(app.libraries ?? []).flatMap((library) => library.copts ?? []),
    ]),
  ].sort()
  const extensionPlatforms = new Set(
    (app.extensions ?? []).map((target) => target.platform),
  )
  const bundlePlatforms = new Set(
    appBundles(app).map((target) => target.platform),
  )
  const loads = [
    ...[...bundlePlatforms].map((platform) =>
      appLoad(platform, extensionPlatforms.has(platform))
    ),
    `load("//bazel/rules:rules.bzl", ${
      [...coptsSymbols, 'wuhu_platforms'].map((symbol) => `"${symbol}"`).join(
        ', ',
      )
    })`,
    `load("@build_bazel_rules_swift//swift:swift_library.bzl", "swift_library")`,
  ]
  const bundles = appBundles(app)
  if (
    app.signingTeamID &&
    bundles.some((target) =>
      variantsFor(app, target).some((variant) =>
        profileName(target, variant, platformsByIdentifier) !== undefined
      )
    )
  ) {
    loads.push(
      `load("@build_bazel_rules_apple//apple:apple.bzl", "local_provisioning_profile")`,
    )
  }
  // Everything tools/lib/manifests.ts opens for this shell. The release-tooling
  // test runs sandboxed against the real tree, so a file the reader follows —
  // the entitlements each target names — has to be a declared input, and this
  // is derived rather than re-listed by hand in tools/BUILD.bazel.
  function releaseManifestFilegroup(sources: readonly string[]): string {
    return `filegroup(\n    name = "release_manifest",\n    srcs = [\n${
      sources.map((source) => `        "${source}",\n`)
        .join('')
    }    ],\n)\n`
  }
  const chunks = [
    ...[...new Set(loads)].sort(),
    `\npackage(default_visibility = ["//visibility:public"])\n`,
    `exports_files(["${shellPath(pathPrefix, 'app.yml')}"])\n`,
    ...(emitReleaseManifest
      ? [
        releaseManifestFilegroup(
          [
            shellPath(pathPrefix, 'app.yml'),
            ...entitlementSources.map((source) =>
              shellPath(pathPrefix, source)
            ),
          ],
        ),
      ]
      : []),
  ]

  for (const target of bundles) {
    if (!app.signingTeamID) continue
    for (const variant of variantsFor(app, target)) {
      const name = profileName(target, variant, platformsByIdentifier)
      if (!name) continue
      chunks.push(
        `local_provisioning_profile(\n    name = "${
          profileTargetName(target, variant)
        }",\n${
          target.platform === 'macOS'
            ? `    profile_extension = ".provisionprofile",\n`
            : ''
        }    profile_name = "${name}",\n    team_id = "${app.signingTeamID}",\n    tags = ["manual"],\n)\n`,
      )
    }
  }

  for (const target of app.extensions ?? []) {
    chunks.push(
      generateAppBundleRule(
        app,
        target,
        extensionRule(target.platform),
        app.name,
        pathPrefix,
        platformsByIdentifier,
        [],
        false,
      ),
    )
  }

  for (const target of app.watchApplications ?? []) {
    chunks.push(
      generateAppBundleRule(
        app,
        target,
        appRule(target.platform),
        app.name,
        pathPrefix,
        platformsByIdentifier,
      ),
    )
  }

  const intentsLibraries = appIntentsLibraries(app)
  for (const library of app.libraries ?? []) {
    const coptsExpr = [
      ...new Set([
        'WUHU_SWIFT_LANGUAGE_MODE_COPTS',
        ...(embedsViewPilot ? ['WUHU_UI_CONTROL_COPTS'] : []),
        ...(library.copts ?? []),
      ]),
    ].join(' + ')
    chunks.push(
      `swift_library(\n    name = "${library.name}",\n    srcs = glob(${
        quotedStarlarkList(
          appLibrarySources(library).map((dir) =>
            `${shellPath(pathPrefix, dir)}/**/*.swift`
          ),
        )
      }),\n    copts = ${coptsExpr},\n${
        // rules_apple's app_intents aspect refuses a library that does not link
        // AppIntents, and Swift autolinking alone leaves no trace of it in the
        // linking context the aspect reads.
        intentsLibraries.has(library.name)
          ? `    linkopts = ${
            quotedStarlarkList(['-framework', 'AppIntents'])
          },\n`
          : ''}    deps = ${quotedStarlarkList(library.dependencies ?? [])},\n${
        platformsAttr(
          appLibraryPlatforms(app, library),
          `${app.name} app.yml`,
        )
      })\n`,
    )
  }

  for (const target of app.targets) {
    chunks.push(
      generateAppBundleRule(
        app,
        target,
        appRule(target.platform),
        app.name,
        pathPrefix,
        platformsByIdentifier,
        (target.extensions ?? []).map((name) => `:${name}`),
        embedsViewPilot,
        target.watchApplication,
      ),
    )
  }

  return chunks.join('\n')
}

function escapeXml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;')
}

function plistValueXml(value: PlistValue, indent: number): string {
  const pad = '\t'.repeat(indent)
  if (typeof value === 'string') {
    return `${pad}<string>${escapeXml(value)}</string>`
  }
  if (typeof value === 'number') {
    return Number.isInteger(value)
      ? `${pad}<integer>${value}</integer>`
      : `${pad}<real>${value}</real>`
  }
  if (typeof value === 'boolean') return `${pad}<${value ? 'true' : 'false'}/>`
  if (Array.isArray(value)) {
    if (!value.length) return `${pad}<array/>`
    return `${pad}<array>\n${
      value.map((item) => plistValueXml(item, indent + 1)).join('\n')
    }\n${pad}</array>`
  }

  const entries = Object.entries(value)
  if (!entries.length) return `${pad}<dict/>`
  return `${pad}<dict>\n${
    entries.map(([key, item]) =>
      `${'\t'.repeat(indent + 1)}<key>${escapeXml(key)}</key>\n${
        plistValueXml(item, indent + 1)
      }`
    ).join('\n')
  }\n${pad}</dict>`
}

function generatePlist(
  info: { [key: string]: PlistValue },
  source = 'Info.plist',
): string {
  validateAppTransportSecurity(info, source)
  return `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0">\n${
    plistValueXml(info, 0)
  }\n</plist>\n`
}

// App shells live beside the library targets they ship, as
// `<package>/Apps/<shell>/app.yml` mirroring `<package>/Targets/<name>/target.yml`.
export async function discoverAppDirs(packageDir: string): Promise<string[]> {
  const root = join(packageDir, 'Apps')
  if (!(await exists(root))) return []
  const appDirs: string[] = []
  for await (const entry of Deno.readDir(root)) {
    if (!entry.isDirectory) continue
    const shellDir = join(root, entry.name)
    if (await exists(join(shellDir, 'app.yml'))) appDirs.push(shellDir)
  }
  return appDirs.sort()
}

const derivedAppInfoKeys = [
  'CFBundleDevelopmentRegion',
  'CFBundleDisplayName',
  'CFBundleIdentifier',
  'CFBundleInfoDictionaryVersion',
  'CFBundleName',
  'CFBundlePackageType',
  'CFBundleShortVersionString',
  'CFBundleVersion',
  'ITSAppUsesNonExemptEncryption',
] as const

function requiredDeviceCapabilities(
  target: AppBundleManifest,
): PlistValue | undefined {
  const declared = target.info.UIRequiredDeviceCapabilities
  if (target.platform === 'macOS') return undefined
  if (target.platform === 'watchOS') {
    if (declared !== undefined) {
      throw new Error(
        `${target.name} UIRequiredDeviceCapabilities is forbidden on watchOS`,
      )
    }
    return undefined
  }
  if (declared === undefined) return ['arm64']
  if (Array.isArray(declared)) {
    return declared.includes('arm64') ? declared : ['arm64', ...declared]
  }
  if (typeof declared === 'object') return { ...declared, arm64: true }
  throw new Error(
    `${target.name} UIRequiredDeviceCapabilities must be an array or dictionary`,
  )
}

export function appBundleInfo(
  app: AppManifest,
  target: AppBundleManifest,
  kind: 'application' | 'extension',
): { [key: string]: PlistValue } {
  for (const key of derivedAppInfoKeys) {
    if (target.info[key] !== undefined) {
      throw new Error(
        `${target.name} info.${key} is generated from typed app.yml fields`,
      )
    }
  }

  const platformDefaults: { [key: string]: PlistValue } = {}
  if (kind === 'application' && target.platform === 'macOS') {
    platformDefaults.NSMainStoryboardFile = ''
  }
  if (kind === 'application' && target.platform === 'iOS') {
    platformDefaults.UILaunchScreen = {}
  }
  const capabilities = requiredDeviceCapabilities(target)

  return {
    CFBundleDevelopmentRegion: app.developmentRegion ?? 'en',
    CFBundleDisplayName: target.displayName ?? target.bundleName,
    CFBundleIdentifier: target.bundleID,
    CFBundleInfoDictionaryVersion: '6.0',
    CFBundleName: target.bundleName,
    CFBundlePackageType: kind === 'extension' ? 'XPC!' : 'APPL',
    CFBundleShortVersionString: app.marketingVersion ?? '1.0',
    CFBundleVersion: '1',
    ...(app.usesNonExemptEncryption === undefined
      ? {}
      : { ITSAppUsesNonExemptEncryption: app.usesNonExemptEncryption }),
    ...platformDefaults,
    ...target.info,
    ...(capabilities === undefined
      ? {}
      : { UIRequiredDeviceCapabilities: capabilities }),
  }
}

// A devIdentity's `info` becomes the complete dev plist, so `variantBundle`
// over a populated bundle yields the populated dev bundle.
export function populateAppBundleInfo(app: AppManifest): void {
  const populate = (
    target: AppBundleManifest,
    kind: 'application' | 'extension',
  ): void => {
    if (target.devIdentity !== undefined) {
      target.devIdentity.info = appBundleInfo(
        app,
        variantBundle(target, 'dev'),
        kind,
      )
    }
    target.info = appBundleInfo(app, target, kind)
    if (
      kind === 'application' &&
      target.bundleID.startsWith('tech.lakeridge.previews.')
    ) {
      const name = target.bundleID.slice('tech.lakeridge.previews.'.length)
      target.info.CFBundleURLTypes = [{
        CFBundleURLName: target.bundleID,
        CFBundleURLSchemes: [`${name}-preview`],
      }]
    }
  }
  for (const target of app.targets) populate(target, 'application')
  for (const target of app.extensions ?? []) populate(target, 'extension')
  for (const target of app.watchApplications ?? []) {
    populate(target, 'application')
  }
}

// Library log subsystems a pilot must be able to read back: without a Persist
// level of their own they age out of the ring buffers before `pilot logs` asks.
// A shell overrides any of them, or adds its own, through `info.OSLogPreferences`.
export const pilotPersistedLibrarySubsystems: readonly string[] = [
  'com.wuhu.canopykit',
]

export function pilotInfo(
  target: AppBundleManifest,
): { [key: string]: PlistValue } {
  const logging = {
    'DEFAULT-OPTIONS': {
      Level: {
        Enable: 'Debug',
        Persist: 'Debug',
      },
    },
  }
  const services = target.info.NSBonjourServices
  const authoredLogging = target.info.OSLogPreferences
  if (
    authoredLogging !== undefined &&
    (authoredLogging === null ||
      typeof authoredLogging !== 'object' ||
      Array.isArray(authoredLogging))
  ) {
    throw new Error(
      `${target.name}.info OSLogPreferences must be a dictionary`,
    )
  }
  const bonjour = Array.isArray(services)
    ? [...new Set([...services as PlistValue[], '_wuhu-pilot._tcp'])]
    : ['_wuhu-pilot._tcp']
  return {
    ...target.info,
    NSBonjourServices: bonjour,
    NSLocalNetworkUsageDescription:
      target.info.NSLocalNetworkUsageDescription ??
        'This development build exposes an in-process UI pilot on this device.',
    OSLogPreferences: {
      ...Object.fromEntries(
        pilotPersistedLibrarySubsystems.map((subsystem) => [
          subsystem,
          logging,
        ]),
      ),
      ...(authoredLogging ?? {}) as { [key: string]: PlistValue },
      [target.bundleID]: logging,
      'tech.lakeridge.view-pilot': logging,
    },
  }
}

async function validateAppResources(
  app: AppManifest,
  appDir: string,
): Promise<void> {
  for (const target of appBundles(app)) {
    for (const resource of target.resources ?? []) {
      if (!(await exists(join(appDir, resource)))) {
        throw new Error(`${target.name} resource does not exist: ${resource}`)
      }
    }
  }
}

export function resolvedEntitlements(
  declared: AppBundleManifest,
  signing: SigningVariant,
  teamID: string,
): { [key: string]: PlistValue } {
  const target = variantBundle(declared, signing)
  const variant = signing === 'dev' ? 'dev' : 'release'
  const values = {
    ...(target.entitlements.common ?? {}),
    ...(variant === 'dev'
      ? target.entitlements.dev ?? {}
      : target.entitlements.release ?? {}),
  }
  const usesICloud = [
    'com.apple.developer.icloud-container-identifiers',
    'com.apple.developer.icloud-services',
    'com.apple.developer.icloud-container-environment',
  ].some((key) => values[key] !== undefined)
  const preview = isPreviewBundle(target)
  if (target.platform === 'macOS') {
    // Both variants sign the identifier in: a store bundle whose signature
    // lacks it is TestFlight-ineligible (ASC 90886) even though upload and
    // App Store review accept it.
    if (!preview) {
      values['com.apple.application-identifier'] =
        `${teamID}.${target.bundleID}`
      if (variant === 'dev') {
        values['com.apple.developer.team-identifier'] = teamID
      }
    }
  } else {
    values['application-identifier'] = `${teamID}.${target.bundleID}`
  }
  if (variant === 'dev') {
    if (
      target.platform !== 'macOS' &&
      (!preview || target.platform === 'iOS')
    ) {
      values['get-task-allow'] = true
    }
    if (
      usesICloud &&
      values['com.apple.developer.icloud-container-environment'] === undefined
    ) {
      values['com.apple.developer.icloud-container-environment'] = 'Production'
    }
  } else {
    values['com.apple.developer.team-identifier'] = teamID
    if (usesICloud) {
      values['com.apple.developer.icloud-container-environment'] = 'Production'
    }
  }
  return values
}

interface PreparedApp {
  app: AppManifest
  pathPrefix: string
  entitlementSources: string[]
}

async function removeGeneratedNestedBuild(appDir: string): Promise<void> {
  for (const name of ['BUILD.bazel', 'BUILD.generated.bazel']) {
    try {
      await Deno.remove(join(appDir, name))
      console.log(`removed ${join(appDir, name)}`)
    } catch (error) {
      if (!(error instanceof Deno.errors.NotFound)) throw error
    }
  }
}

async function prepareApp(
  appDir: string,
  packageDir: string,
  teamID: string,
): Promise<PreparedApp> {
  const source = join(appDir, 'app.yml')
  const app = await readYaml<AppManifest>(source)
  validateAppTransportSecurity(app, source)
  validateAppRelease(app, source)
  validateAppExtensions(app, source)
  validateAppIntents(app, source)
  validateAppEntitlements(app, source)
  await validateAppResources(app, appDir)
  app.signingTeamID = teamID
  populateAppBundleInfo(app)
  const bundles = appBundles(app)
  const entitlementSources: string[] = []

  for (const target of bundles) {
    const embedsViewPilot = bundleEmbedsViewPilot(app, target)
    const plists = infoPlistPaths(target, embedsViewPilot)
    const written = new Set<string>()
    for (const variant of ['dev', 'store', 'adhoc'] as const) {
      const path = plists[variant]
      if (written.has(path)) continue
      written.add(path)
      const bundle = variantBundle(target, variant)
      const output = join(appDir, path)
      await Deno.mkdir(dirname(output), { recursive: true })
      await writeIfChanged(
        output,
        generatePlist(
          variant === 'dev' && embedsViewPilot
            ? pilotInfo(bundle)
            : bundle.info,
          output,
        ),
      )
    }
    const sources = entitlementSourcesByVariant(app, target)
    for (const [path, variant] of sources) {
      entitlementSources.push(path)
      await writeIfChanged(
        join(appDir, path),
        generatePlist(resolvedEntitlements(target, variant, teamID)),
      )
    }
    for (const file of ['adhoc', 'release']) {
      const path = `${target.name}-${file}.entitlements`
      if (!sources.has(path)) await removeIfPresent(join(appDir, path))
    }
  }
  await removeGeneratedNestedBuild(appDir)
  return {
    app,
    pathPrefix: relative(packageDir, appDir),
    entitlementSources: entitlementSources.sort(),
  }
}

// Xcode resolves a local package through its Package.swift, and a package that
// reaches a sibling by path pulls that sibling's manifest in too.
export async function localPathClosure(packageDir: string): Promise<string[]> {
  const closure: string[] = []
  const queue = [normalize(packageDir)]
  while (queue.length) {
    const current = queue.shift()!
    if (closure.includes(current)) continue
    closure.push(current)
    const pkg = await readPackageManifest(current)
    for (const external of Object.values(pkg.externalPackages ?? {})) {
      if (external.path) queue.push(normalize(join(current, external.path)))
    }
  }
  return closure
}

async function localPackageRefs(
  app: AppManifest,
  appDir: string,
): Promise<Record<string, LocalPackageRef>> {
  const labels = [
    ...app.targets.flatMap((target) => target.dependencies),
    ...app.targets.flatMap((target) => target.frameworks ?? []),
    ...(app.extensions ?? []).flatMap((target) => target.dependencies),
    ...(app.extensions ?? []).flatMap((target) => target.frameworks ?? []),
    ...(app.watchApplications ?? []).flatMap((target) => target.dependencies),
    ...(app.watchApplications ?? []).flatMap((target) =>
      target.frameworks ?? []
    ),
    ...(app.libraries ?? []).flatMap((library) => library.dependencies ?? []),
  ]
  const refs: Record<string, LocalPackageRef> = {}
  for (const label of labels) {
    const match = /^\/\/(.+):(.+)$/.exec(label)
    if (!match || refs[match[1]]) continue
    const dir = match[1]
    if (!(await exists(join(dir, 'package.yml')))) continue
    const pkg = await readPackageManifest(dir)
    refs[dir] = {
      name: pkg.packageName,
      products: productTargets(pkg, await discoverTargets(dir)).map(
        (target) => target.name,
      ),
      path: relative(appDir, dir),
    }
  }
  return refs
}

async function resolveXcodegen(): Promise<string> {
  const which = await new Deno.Command('which', {
    args: ['xcodegen'],
    stdout: 'piped',
    stderr: 'null',
  }).output()
  const path = new TextDecoder().decode(which.stdout).trim().split('\n')[0]
  if (!which.success || !path) {
    throw new Error(
      '--workspace shells out to XcodeGen for the app-shell project, and xcodegen is not on PATH. Install it with `brew install xcodegen`. It is an interactive-editing convenience only: nothing in CI, the Bazel graph, or agent workflows needs it.',
    )
  }
  return path
}

async function generateXcodeWorkspace(packageDir: string): Promise<void> {
  if (!apply) {
    throw new Error(
      '--workspace needs --apply: Xcode reads Package.swift and BUILD-adjacent plists at their real paths, not the .generated preview names.',
    )
  }
  const teamID = await signingTeamID()
  const appDirs = await discoverAppDirs(packageDir)
  if (appDirs.length === 0) {
    throw new Error(
      `${packageDir} declares no app shell under Apps/, so an Xcode workspace would have nothing to run on a simulator or device.`,
    )
  }
  const xcodegen = await resolveXcodegen()

  const projectPaths: string[] = []
  for (const appDir of appDirs) {
    const app = await readYaml<AppManifest>(join(appDir, 'app.yml'))
    validateAppEntitlements(app, join(appDir, 'app.yml'))
    app.signingTeamID = teamID
    populateAppBundleInfo(app)
    const localPath = join(appDir, '.xcodegen-local.yml')
    const local = (await exists(localPath))
      ? await readYaml<WorkspaceLocalConfig>(localPath)
      : {}
    const { spec, unresolved } = xcodeProjectSpec(
      app,
      await localPackageRefs(app, appDir),
      local,
    )
    for (const target of appBundles(app)) {
      const plistPath = join(appDir, xcodeInfoPlistPath(target))
      await Deno.mkdir(dirname(plistPath), { recursive: true })
      await writeIfChanged(
        plistPath,
        generatePlist(xcodeInfoPlist(variantBundle(target, 'dev').info)),
      )
      await writeIfChanged(
        join(appDir, xcodeShellSourcePath(target)),
        xcodeShellSource(target),
      )
    }
    const specPath = join(appDir, '.xcodegen.json')
    await writeIfChanged(specPath, `${JSON.stringify(spec, null, 2)}\n`)
    const generated = await new Deno.Command(xcodegen, {
      args: ['generate', '--spec', specPath, '--project', appDir, '--quiet'],
    }).output()
    if (!generated.success) {
      throw new Error(`xcodegen failed for ${specPath}`)
    }
    for (const name of unresolved) {
      console.log(`xcode workspace: left out Bazel-only dependency ${name}`)
    }
    projectPaths.push(
      relative(dirname(packageDir), join(appDir, `${app.name}.xcodeproj`)),
    )
  }

  const workspaceDir = join(
    dirname(packageDir),
    `${basename(packageDir)}.xcworkspace`,
  )
  await Deno.mkdir(workspaceDir, { recursive: true })
  await writeIfChanged(
    join(workspaceDir, 'contents.xcworkspacedata'),
    workspaceContents(basename(packageDir), projectPaths),
  )
  console.log(`xcode workspace: open ${workspaceDir}`)
}

// On a case-insensitive mount whose realpath does not canonicalize case (a
// Linux container over an OrbStack bind of a mac checkout — PR #1270's report)
// "Packages" stats as packages/ itself while case-sensitive
// `git ls-files -- Packages` returns empty, so every name-based guard passes
// and removal deletes packages/. Only inode identity distinguishes the two;
// refuse removal unless provably distinct.
export function isRemovableLegacyPackages(
  legacy: Pick<Deno.FileInfo, 'dev' | 'ino'>,
  current: Pick<Deno.FileInfo, 'dev' | 'ino'>,
): boolean {
  if (legacy.ino === null || current.ino === null) return false
  return legacy.dev !== current.dev || legacy.ino !== current.ino
}

async function removeLegacyPackagesIfNeeded(): Promise<void> {
  const legacy = 'Packages'
  const current = 'packages'
  if (!(await exists(legacy)) || !(await exists(current))) return

  if (
    !isRemovableLegacyPackages(
      await Deno.stat(legacy),
      await Deno.stat(current),
    )
  ) {
    return
  }

  const tracked = await new Deno.Command('git', {
    args: ['ls-files', '--', legacy],
    stdout: 'piped',
  }).output()
  if (!tracked.success) {
    throw new Error('Could not inspect tracked files under legacy Packages/.')
  }
  const trackedFiles = new TextDecoder().decode(tracked.stdout).trim()
  if (trackedFiles.length > 0) {
    throw new Error(
      'Refusing to remove legacy Packages/: it still contains tracked files.',
    )
  }

  await Deno.remove(legacy, { recursive: true })
  console.log('removed stale legacy Packages/')
}

export async function main(rawArgs: string[] = Deno.args): Promise<void> {
  generatedOutputs.clear()
  configure(rawArgs)
  await removeLegacyPackagesIfNeeded()

  swiftPMPackages = workspacePackage
    ? await localPathClosure(workspacePackage)
    : []

  const requested = generateAll
    ? await discoverPackageDirs('packages')
    : packageArgs.length
    ? packageArgs
    : workspacePackage
    ? []
    : ['packages/wuhu-core']
  const packageDirs = [...new Set([...requested, ...swiftPMPackages])]

  for (const packageDir of packageDirs) {
    await generatePackage(packageDir)
  }

  if (generateAll) {
    assertPublicEdges(await discoverOwnedPackages('packages'))
    const denoWorkspaces = await discoverDenoWorkspaces('packages')
    const denoPackageDirs = await discoverDenoPackageDirs('packages')
    await writeIfChanged(
      apply ? '.bazelignore' : '.bazelignore.generated',
      bazelIgnore(
        [...denoPackageDirs, ...denoWorkspaceRootDirs(denoWorkspaces)],
        packageDirs,
      ),
    )
    for (const rootDir of denoWorkspaceRootDirs(denoWorkspaces)) {
      await writeIfChanged(
        join(rootDir, apply ? 'BUILD.bazel' : 'BUILD.generated.bazel'),
        denoWorkspaceRootBuildBazel(),
      )
    }
    for (const packageDir of denoPackageDirs) {
      await generateDenoPackage(packageDir, denoWorkspaces.get(packageDir))
    }
  }

  if (generateUmbrella) {
    const umbrellaOutput = apply
      ? 'bazel/umbrella/Package.swift'
      : 'bazel/umbrella/Package.generated.swift'
    await writeIfChanged(
      umbrellaOutput,
      await generateUmbrellaPackageSwift(packageDirs),
    )
  }

  if (generateModule) {
    const moduleOutput = apply ? 'MODULE.bazel' : 'MODULE.generated.bazel'
    await writeIfChanged(
      moduleOutput,
      await generateModuleBazel(packageDirs),
    )
  }

  if (workspacePackage) {
    await generateXcodeWorkspace(workspacePackage)
  }

  if (
    apply && generateAll && generateUmbrella && generateModule &&
    workspacePackage === undefined
  ) {
    await Deno.mkdir('.wuhu', { recursive: true })
    await writeIfChanged(
      '.wuhu/manifest-outputs',
      `${[...generatedOutputs].sort().join('\n')}\n`,
    )
    await replaceFile(
      '.wuhu/manifest-provenance',
      `${await manifestFingerprint()}\n`,
    )
    await replaceFile('.wuhu/manifest-stamp', '')
  }
}

if (import.meta.main) {
  await main()
}
