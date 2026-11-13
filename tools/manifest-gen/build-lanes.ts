import type { CheckPlatform } from './generate.ts'

export interface BuildLaneTarget {
  platforms: readonly CheckPlatform[]
  host: boolean
  dependencies: readonly {
    label: string
    platforms?: readonly CheckPlatform[]
  }[]
}

export interface BuildLaneViolation {
  importer: string
  dependency: string
  platform: CheckPlatform
}

export class BuildLaneError extends Error {
  constructor(readonly violations: readonly BuildLaneViolation[]) {
    super(
      `A dependency is unavailable in its importer's build lane:\n  ${
        violations.map(({ importer, dependency, platform }) =>
          `${importer} imports ${dependency} on ${platform}`
        ).join('\n  ')
      }\nNarrow the importer's checks or enable the dependency's lane (docs/bazel.md, "Platform floors").`,
    )
    this.name = 'BuildLaneError'
  }
}

export function assertBuildLaneEdges(
  targets: ReadonlyMap<string, BuildLaneTarget>,
): void {
  const violations: BuildLaneViolation[] = []
  for (const [importer, target] of targets) {
    if (target.host) continue
    for (const edge of target.dependencies) {
      const dependency = targets.get(edge.label)
      if (!dependency || dependency.host) continue
      for (const platform of target.platforms) {
        if (edge.platforms && !edge.platforms.includes(platform)) continue
        if (!dependency.platforms.includes(platform)) {
          violations.push({ importer, dependency: edge.label, platform })
        }
      }
    }
  }
  if (violations.length) throw new BuildLaneError(violations)
}
