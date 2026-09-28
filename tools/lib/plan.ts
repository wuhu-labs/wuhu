export type Platform = 'mac' | 'ios' | 'tvos' | 'visionos'

export interface PlatformRow {
  readonly manifestPlatform: 'macOS' | 'iOS' | 'tvOS' | 'visionOS'
  readonly cpuFlags: readonly string[]
  // Preference order for picking the app out of cquery's file list. How that
  // artifact is opened is read from its extension, not from the platform:
  // visionOS's app rule hands back a bare .app where iOS hands back an .ipa.
  readonly artifactSuffixes: readonly string[]
}

// The `--apple_platform_type`/`--cpu` pairs are deliberately NOT the
// `--platforms` spelling the CI lanes use. An application rule transitions its
// own configuration, and only the legacy pair reaches its device/simulator
// choice: under `--platforms=...ios_arm64` the bundle still comes out
// ios_sim_arm64, while `--cpu=ios_arm64` makes rules_apple build for device (it
// then demands a provisioning profile selected by `--config=sign-store`). A
// release archive must be a device slice, so these stay.
//
// A new Apple platform is exactly one row here plus targets in the app's
// app.yml. Nothing else in the release drivers may name a platform.
export const platformTable: Readonly<Record<Platform, PlatformRow>> = {
  mac: {
    manifestPlatform: 'macOS',
    cpuFlags: ['--apple_platform_type=macos', '--cpu=darwin_arm64'],
    artifactSuffixes: ['.zip', '.app'],
  },
  ios: {
    manifestPlatform: 'iOS',
    cpuFlags: ['--apple_platform_type=ios', '--cpu=ios_arm64'],
    artifactSuffixes: ['.ipa', '.app', '.zip'],
  },
  tvos: {
    manifestPlatform: 'tvOS',
    cpuFlags: ['--apple_platform_type=tvos', '--cpu=tvos_arm64'],
    artifactSuffixes: ['.ipa', '.app', '.zip'],
  },
  visionos: {
    manifestPlatform: 'visionOS',
    cpuFlags: ['--apple_platform_type=visionos', '--cpu=visionos_arm64'],
    artifactSuffixes: ['.ipa', '.app', '.zip'],
  },
}

export const platforms: readonly Platform[] = Object.keys(
  platformTable,
) as Platform[]

export function platformOfManifest(value: string): Platform {
  const found = platforms.find((platform) =>
    platformTable[platform].manifestPlatform === value
  )
  if (!found) throw new Error(`Unknown app.yml platform: ${value}`)
  return found
}

export type Value =
  | string
  | { readonly binding: string }
  | { readonly join: readonly Value[] }

export type ObservationKind =
  | 'cquery-files'
  | 'execution-root'
  | 'codesigning-identities'
  | 'notarization-result'
  | 'text'

export type PackFormat = 'zip-ditto' | 'tar-zstd' | 'tar-gzip' | 'unzip'

export type TransferTarget = 'staging' | 'r2'

export interface Retry {
  readonly attempts: number
  readonly backoffMs: number
}

export interface EntitlementExpectation {
  readonly applicationIdentifier: string
  readonly teamIdentifier: string
  readonly keychainAccessGroups: readonly string[]
}

export type Step =
  | { readonly kind: 'generate-manifests'; readonly flags: readonly string[] }
  | {
    readonly kind: 'command'
    readonly argv: readonly Value[]
    readonly cwd?: Value
    readonly retry?: Retry
  }
  | {
    readonly kind: 'capture'
    readonly argv: readonly Value[]
    readonly into: string
    readonly observe: ObservationKind
  }
  | { readonly kind: 'mkdir'; readonly path: Value }
  | { readonly kind: 'remove'; readonly path: Value }
  | { readonly kind: 'temp-dir'; readonly into: string }
  | {
    readonly kind: 'copy'
    readonly from: Value
    readonly to: Value
    readonly as: 'file' | 'bundle'
  }
  | {
    readonly kind: 'chmod'
    readonly path: Value
    readonly mode: string
    readonly recursive: boolean
  }
  | { readonly kind: 'write-file'; readonly path: Value; readonly text: string }
  | {
    readonly kind: 'plist-upsert'
    readonly path: Value
    readonly entries: Readonly<Record<string, string>>
  }
  | {
    readonly kind: 'pack'
    readonly format: PackFormat
    readonly source: Value
    readonly output: Value
    readonly cwd?: Value
  }
  | {
    readonly kind: 'unpack'
    readonly format: PackFormat
    readonly source: Value
    readonly destination: Value
  }
  | {
    readonly kind: 'find-bundle'
    readonly root: Value
    readonly suffix: string
    readonly into: string
  }
  | {
    readonly kind: 'checksum'
    readonly source: Value
    readonly sidecar: Value
    readonly algorithm: 'sha256'
  }
  | {
    readonly kind: 'assert-command-output'
    readonly argv: readonly Value[]
    readonly startsWith: string
    readonly message: string
  }
  | {
    readonly kind: 'assert-entitlements'
    readonly app: Value
    readonly expect: EntitlementExpectation
  }
  | { readonly kind: 'assert-static-runtime'; readonly binary: Value }
  | { readonly kind: 'normalize-macos-frameworks'; readonly app: Value }
  | {
    readonly kind: 'codesign'
    readonly path: Value
    readonly identity: Value
    readonly options: readonly string[]
  }
  | { readonly kind: 'notarize'; readonly archive: Value }
  | {
    readonly kind: 'transfer'
    readonly direction: 'upload' | 'download'
    readonly target: TransferTarget
    readonly local: Value
    readonly key: string
    readonly contentType?: string
    readonly cacheControl?: string
    readonly retry?: Retry
  }

export interface StageHandoff {
  readonly stage: string
  readonly needs: readonly string[]
}

// A Plan never carries a credential. Transfer steps name a target role and
// notarize names none; execute() resolves both from the environment at run
// time, so a Plan stays safe to print, diff, and check in as a golden.
export interface Plan {
  readonly schema: 1
  readonly name: string
  readonly subject: string
  readonly steps: readonly Step[]
  readonly outputs: Readonly<Record<string, Value>>
  readonly next?: StageHandoff
}

export type Observations = Readonly<
  Record<string, string | readonly string[]>
>

export interface PlanTranscript {
  readonly request: Readonly<Record<string, unknown>>
  readonly stage1: Plan
  readonly observations: Observations
  readonly stage2: Plan | null
}

export function formatPlan(value: unknown): string {
  return `${JSON.stringify(value, null, 2)}\n`
}

const stepKinds = new Set<string>([
  'generate-manifests',
  'command',
  'capture',
  'mkdir',
  'remove',
  'temp-dir',
  'copy',
  'chmod',
  'write-file',
  'plist-upsert',
  'pack',
  'unpack',
  'find-bundle',
  'checksum',
  'assert-command-output',
  'assert-entitlements',
  'assert-static-runtime',
  'normalize-macos-frameworks',
  'codesign',
  'notarize',
  'transfer',
])

function assertValue(value: unknown, where: string): void {
  if (typeof value === 'string') return
  if (typeof value !== 'object' || value === null) {
    throw new Error(`${where}: not a plan value`)
  }
  const record = value as Record<string, unknown>
  if (typeof record.binding === 'string') return
  if (Array.isArray(record.join)) {
    record.join.forEach((part, index) =>
      assertValue(part, `${where}.join[${index}]`)
    )
    return
  }
  throw new Error(`${where}: not a plan value`)
}

export function parsePlan(text: string): Plan {
  const value = JSON.parse(text) as Record<string, unknown>
  if (value.schema !== 1) throw new Error('plan schema must be 1')
  if (typeof value.name !== 'string') {
    throw new Error('plan name must be a string')
  }
  if (typeof value.subject !== 'string') {
    throw new Error('plan subject must be a string')
  }
  if (!Array.isArray(value.steps)) {
    throw new Error('plan steps must be an array')
  }
  value.steps.forEach((step, index) => {
    const record = step as Record<string, unknown>
    if (typeof record.kind !== 'string' || !stepKinds.has(record.kind)) {
      throw new Error(`steps[${index}]: unknown kind ${String(record.kind)}`)
    }
    if (Array.isArray(record.argv)) {
      record.argv.forEach((argument, position) =>
        assertValue(argument, `steps[${index}].argv[${position}]`)
      )
    }
    for (
      const key of [
        'path',
        'from',
        'to',
        'source',
        'output',
        'destination',
        'local',
        'app',
        'binary',
        'archive',
        'root',
        'sidecar',
        'cwd',
        'identity',
      ]
    ) {
      if (record[key] !== undefined) {
        assertValue(record[key], `steps[${index}].${key}`)
      }
    }
  })
  const outputs = value.outputs
  if (typeof outputs !== 'object' || outputs === null) {
    throw new Error('plan outputs must be an object')
  }
  for (const [key, output] of Object.entries(outputs)) {
    assertValue(output, `outputs.${key}`)
  }
  return value as unknown as Plan
}

export function declaredBinding(step: Step): string | null {
  if (step.kind === 'capture') return step.into
  if (step.kind === 'temp-dir') return step.into
  if (step.kind === 'find-bundle') return step.into
  return null
}

function referencedBindings(value: unknown, found: Set<string>): void {
  if (typeof value !== 'object' || value === null) return
  const record = value as Record<string, unknown>
  if (typeof record.binding === 'string') {
    found.add(record.binding)
    return
  }
  for (const child of Object.values(record)) {
    if (Array.isArray(child)) {
      child.forEach((item) => referencedBindings(item, found))
    } else referencedBindings(child, found)
  }
}

export function assertBindingsResolvable(plan: Plan): void {
  const available = new Set<string>()
  for (const [index, step] of plan.steps.entries()) {
    const used = new Set<string>()
    referencedBindings(step, used)
    for (const name of used) {
      if (!available.has(name)) {
        throw new Error(
          `${plan.name} steps[${index}] (${step.kind}) reads undeclared binding ${name}`,
        )
      }
    }
    const declared = declaredBinding(step)
    if (declared !== null) available.add(declared)
  }
  const used = new Set<string>()
  referencedBindings(plan.outputs, used)
  for (const name of used) {
    if (!available.has(name)) {
      throw new Error(`${plan.name} outputs read undeclared binding ${name}`)
    }
  }
}

export function parseTranscript(text: string): PlanTranscript {
  const value = JSON.parse(text) as Record<string, unknown>
  const stage1 = parsePlan(JSON.stringify(value.stage1))
  const stage2 = value.stage2 === null || value.stage2 === undefined
    ? null
    : parsePlan(JSON.stringify(value.stage2))
  return {
    request: value.request as Readonly<Record<string, unknown>>,
    stage1,
    observations: value.observations as Observations,
    stage2,
  }
}
