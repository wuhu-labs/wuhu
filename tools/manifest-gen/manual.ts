import { basename, join, normalize } from '@std/path'
import type {
  AppManifest,
  PackageManifest,
  TargetManifest,
} from './generate.ts'

export interface ManualPackage {
  dir: string
  manifest: PackageManifest
  targets: TargetManifest[]
  apps: { source: string; app: AppManifest }[]
}

export function validateManual(value: unknown, source: string): void {
  if (value !== undefined && typeof value !== 'boolean') {
    throw new Error(`${source}: manual must be a boolean`)
  }
}

function resourceHelpers(name: string): string[] {
  return [
    '_resource_bundle',
    '_resource_bundle_infoplist',
    '_bundle_module_accessor',
  ]
    .map((suffix) => `${name}${suffix}`)
}

export function assertManualBoundaries(
  packages: readonly ManualPackage[],
): void {
  const manual = new Map<string, string>()
  for (const pkg of packages) {
    const register = (names: string[], source: string) => {
      for (const name of names) manual.set(`//${pkg.dir}:${name}`, source)
    }
    for (const target of pkg.targets) {
      const source = `${target.manifestDir}/target.yml`
      validateManual(target.manual, source)
      if (!target.manual) continue
      const tests = [
        ...(target.tests
          ? [{ name: `${target.name}Tests`, config: target.tests }]
          : []),
        ...(target.additionalTestTargets ?? []).map((test) => ({
          name: `${target.name}${basename(test.sources)}`,
          config: test,
        })),
      ]
      register([
        target.name,
        ...(target.kind === 'executable' && target.productName
          ? [target.productName]
          : []),
        ...(target.stamp
          ? [`${target.name}_unstamped`, `${target.name}_stamp`]
          : []),
        ...(target.info ? [`${target.name}_info_plist`] : []),
        ...(target.openapiGenerate ? [`${target.name}_gen`] : []),
        ...(['cLibrary', 'systemLibrary'].includes(target.kind)
          ? [`${target.name}_swift_interop`]
          : []),
        ...(target.resources?.length ? resourceHelpers(target.name) : []),
        ...(target.embeddedResources ?? []).flatMap((resource) =>
          ['sources', 'c', 'swift', 'payload', 'cc'].map((suffix) =>
            `${target.name}_${resource.name}_embedded_directory_${suffix}`
          )
        ),
        ...tests.flatMap(({ name, config }) => [
          name,
          ...(config.resources?.length ? resourceHelpers(name) : []),
          ...(config.macBundle ? [`${name}.library`, `${name}.runner`] : []),
          ...['ios', 'tvos', 'visionos'].flatMap((lane) => [
            `${name}.${lane}`,
            `${name}.${lane}.library`,
            `${name}.${lane}.runner`,
            ...(config.hostResources?.length ? [`${name}.${lane}.host`] : []),
            ...(config.resources?.length
              ? resourceHelpers(`${name}.${lane}`)
              : []),
          ]),
        ]),
      ], source)
    }
    for (const { source, app } of pkg.apps) {
      validateManual(app.manual, source)
      if (!app.manual) continue
      register([
        ...(app.libraries ?? []).map((library) => library.name),
        ...[
          ...app.targets,
          ...(app.extensions ?? []),
          ...(app.watchApplications ?? []),
        ]
          .flatMap((bundle) => [
            bundle.name,
            ...(app.hmr && app.targets.includes(bundle) &&
                ['macOS', 'iOS', 'visionOS'].includes(bundle.platform)
              ? [`${bundle.name}HMR`, `${bundle.name}_hmr_plist`]
              : []),
          ]),
      ], source)
    }
  }

  for (const pkg of packages) {
    const localNames = new Set(pkg.targets.map((target) => target.name))
    const label = (name: string): string => {
      if (name.startsWith('//') || name.startsWith('@')) return name
      if (name.startsWith(':')) return `//${pkg.dir}${name}`
      if (!localNames.has(name)) {
        for (
          const external of Object.values(pkg.manifest.externalPackages ?? {})
        ) {
          const product = Array.isArray(external.products)
            ? external.products.includes(name) ? name : undefined
            : external.products[name]
          const path = external.bazelPackage ??
            (external.path
              ? `//${normalize(join(pkg.dir, external.path))}`
              : undefined)
          if (product && path) return `${path}:${product}`
        }
      }
      return `//${pkg.dir}:${name}`
    }
    const check = (
      source: string,
      owner: string,
      dependencies: TargetManifest['dependencies'],
    ) => {
      for (const dep of dependencies ?? []) {
        if (typeof dep !== 'string' && dep.bazel === false) continue
        const resolved = label(typeof dep === 'string' ? dep : dep.name)
        const producer = manual.get(resolved)
        if (producer) {
          throw new Error(
            `${source}: ordinary ${owner} depends on manual ${resolved} (${producer}); daily checks must not reach a manual target`,
          )
        }
      }
    }
    for (const target of pkg.targets) {
      if (target.manual) continue
      const source = `${target.manifestDir}/target.yml`
      check(source, target.name, target.dependencies)
      check(
        source,
        target.name,
        target.embeddedResources?.flatMap((resource) =>
          resource.target ? [resource.target] : []
        ),
      )
      for (
        const test of [
          ...(target.tests ? [target.tests] : []),
          ...(target.additionalTestTargets ?? []),
        ]
      ) {
        if (test.tags?.includes('manual')) continue
        check(source, `${target.name} test`, [
          ...(test.dependencies ?? []),
          ...Object.values(test.host ?? {}),
          ...(test.externalData ?? []),
          ...Object.values(test.platformRuntime ?? {}).flatMap((runtime) =>
            runtime.externalData ?? []
          ),
        ])
      }
    }
    for (const { source, app } of pkg.apps) {
      if (app.manual) continue
      for (const library of app.libraries ?? []) {
        check(source, library.name, library.dependencies)
      }
      for (
        const bundle of [
          ...app.targets,
          ...(app.extensions ?? []),
          ...(app.watchApplications ?? []),
        ]
      ) {
        check(source, bundle.name, [
          ...bundle.dependencies,
          ...(bundle.frameworks ?? []),
          ...(bundle.appIntents ?? []),
        ])
      }
      for (const target of app.targets) {
        check(source, target.name, [
          ...(target.extensions ?? []),
          ...(target.watchApplication ? [target.watchApplication] : []),
        ])
      }
    }
  }
}
