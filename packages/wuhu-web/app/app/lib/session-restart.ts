import type {
  ModelGroupDescriptor,
  ProviderDescriptor,
  SessionRestartInput,
} from './contract.gen.ts'
import {
  type ModelChoice,
  pickGroup,
  type Unmatched,
} from './session-create.ts'
import type { ExecutorSpec } from './session-model.ts'

// Start over opens on the live spec, not on defaults. A model the catalog no
// longer offers stays unpicked, and the server refuses to keep it, so the
// person must pick one; an effort it no longer offers stays unpicked too.
// A group session opens on its group: the spec names only the member it runs on.
export function adoptSpec(
  providers: ProviderDescriptor[],
  spec: ExecutorSpec,
  groups: ModelGroupDescriptor[] = [],
  routeGroup: string | null = null,
): { choice: ModelChoice; unmatched: Unmatched } {
  if (routeGroup != null) {
    const group = groups.find((g) => g.id === routeGroup)
    const empty = { provider: '', model: null, effort: null }
    if (group == null) {
      return {
        choice: { ...empty, group: null },
        unmatched: { model: null, effort: null, group: routeGroup },
      }
    }
    const effort = spec.effort ?? null
    const offered = effort != null && group.effortLevels.includes(effort)
    return {
      choice: pickGroup(empty, group, effort),
      unmatched: { model: null, effort: offered ? null : effort, group: null },
    }
  }
  const provider = spec.provider ?? ''
  const model = providers.find((p) => p.id === provider)?.models.find((m) =>
    m.id === spec.model
  )
  if (model == null) {
    return {
      choice: { provider, model: null, effort: null },
      unmatched: { model: spec.model ?? null, effort: null },
    }
  }
  const effort = spec.effort ?? null
  const offered = effort != null && model.effortLevels.includes(effort)
  return {
    choice: { provider, model, effort: offered ? effort : null },
    unmatched: { model: null, effort: offered ? null : effort },
  }
}

// Null until a model is picked, since the server refuses a restart onto a
// model it no longer offers. An untouched live spec is left out, and the
// session keeps what it has.
export function restartInput(
  choice: ModelChoice,
  live: ExecutorSpec,
  opening: string,
  timezone: string,
  liveGroup: string | null = null,
): SessionRestartInput | null {
  const message = opening.trim()
  const opened = message === '' ? {} : { message }
  if (choice.group != null) {
    const untouched = choice.group.id === liveGroup &&
      choice.effort === (live.effort ?? null)
    return {
      ...(untouched ? {} : {
        modelGroup: choice.group.id,
        ...(choice.effort == null ? {} : { effort: choice.effort }),
      }),
      ...opened,
      timezone,
    }
  }
  if (choice.model == null) return null
  const untouched = liveGroup == null && choice.provider === live.provider &&
    choice.model.id === live.model &&
    choice.effort === (live.effort ?? null)
  return {
    ...(untouched ? {} : {
      provider: choice.provider,
      model: choice.model.id,
      ...(choice.effort == null ? {} : { effort: choice.effort }),
    }),
    ...opened,
    timezone,
  }
}
