import type { ProviderDescriptor, SessionRestartInput } from './contract.gen.ts'
import type { ModelChoice, Unmatched } from './session-create.ts'
import type { ExecutorSpec } from './session-model.ts'

// Start over opens on the live spec, not on defaults. A model the catalog no
// longer offers stays unpicked, and the server refuses to keep it, so the
// person must pick one; an effort it no longer offers stays unpicked too.
export function adoptSpec(
  providers: ProviderDescriptor[],
  spec: ExecutorSpec,
): { choice: ModelChoice; unmatched: Unmatched } {
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
): SessionRestartInput | null {
  if (choice.model == null) return null
  const untouched = choice.provider === live.provider &&
    choice.model.id === live.model &&
    choice.effort === (live.effort ?? null)
  const message = opening.trim()
  return {
    ...(untouched ? {} : {
      provider: choice.provider,
      model: choice.model.id,
      ...(choice.effort == null ? {} : { effort: choice.effort }),
    }),
    ...(message === '' ? {} : { message }),
    timezone,
  }
}
