import type {
  ProviderDescriptor,
  ProviderModel,
  SessionCreateInput,
  SessionKindPayload,
  SessionTemplateDescriptor,
} from './contract.gen.ts'

export type SessionKind = SessionKindPayload

export interface ModelChoice {
  provider: string
  model: ProviderModel | null
  effort: string | null
}

// What a live spec names that the catalog no longer offers.
export interface Unmatched {
  model: string | null
  effort: string | null
}

export interface SessionDraft extends ModelChoice {
  title: string
  template: string | null
}

export type DraftResult =
  | { input: SessionCreateInput }
  | { error: string }

export const emptyDraft: SessionDraft = {
  title: '',
  provider: '',
  model: null,
  effort: null,
  template: null,
}

export function selectableProviders(
  providers: ProviderDescriptor[],
): ProviderDescriptor[] {
  return providers.filter((provider) => provider.models.length > 0)
}

export function modelOf(
  provider: ProviderDescriptor | undefined,
  id: string | null,
): ProviderModel | null {
  if (provider == null || id == null) return null
  return provider.models.find((model) => model.id === id) ?? null
}

export function defaultModelOf(
  provider: ProviderDescriptor | undefined,
): ProviderModel | null {
  return provider?.models[0] ?? null
}

export function defaultEffortOf(model: ProviderModel | null): string | null {
  if (model == null || model.effortLevels.length === 0) return null
  if (model.defaultEffort == null) return null
  return model.effortLevels.includes(model.defaultEffort)
    ? model.defaultEffort
    : null
}

// A person creates agents only; a task is created by its parent session.
export function agentTemplates(
  templates: SessionTemplateDescriptor[],
): SessionTemplateDescriptor[] {
  return templates.filter((template) => template.kind !== 'task')
}

export function applyTemplate(
  draft: SessionDraft,
  template: SessionTemplateDescriptor | null,
  providers: ProviderDescriptor[],
): SessionDraft {
  if (template == null) return { ...draft, template: null }
  const provider = providers.find((p) => p.id === template.provider)
  if (provider == null) return { ...draft, template: template.name }
  const model = modelOf(provider, template.model ?? null) ??
    defaultModelOf(provider)
  const effort = template.effort
  const offered = effort != null &&
    (model?.effortLevels.includes(effort) ?? false)
  return {
    ...draft,
    template: template.name,
    provider: provider.id,
    model,
    effort: offered ? effort : defaultEffortOf(model),
  }
}

export function draftReady(draft: SessionDraft): boolean {
  return draft.title.trim() !== '' &&
    draft.provider !== '' && draft.model != null
}

export function sessionCreateInput(draft: SessionDraft): DraftResult {
  const title = draft.title.trim()
  if (title === '') return { error: 'a title is required' }
  if (draft.provider === '' || draft.model == null) {
    return { error: 'pick a model' }
  }
  const effort = draft.effort
  return {
    input: {
      title,
      kind: 'agent',
      provider: draft.provider,
      model: draft.model.id,
      ...(effort == null || effort === '' ? {} : { effort }),
      ...(draft.template == null ? {} : { template: draft.template }),
    },
  }
}
