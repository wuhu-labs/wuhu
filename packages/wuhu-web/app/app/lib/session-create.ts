import type {
  ModelGroupDescriptor,
  ProviderDescriptor,
  ProviderModel,
  SessionCreateInput,
  SessionKindPayload,
  SessionTemplateDescriptor,
} from './contract.gen.ts'

export type SessionKind = SessionKindPayload

// A group is a target of its own: with one picked, provider and model stay
// empty and the session runs on whichever member the server places it.
export interface ModelChoice {
  provider: string
  model: ProviderModel | null
  effort: string | null
  group?: ModelGroupDescriptor | null
}

// What a live spec names that the catalog no longer offers.
export interface Unmatched {
  model: string | null
  effort: string | null
  group?: string | null
}

export interface ModelCatalog {
  providers: ProviderDescriptor[]
  groups: ModelGroupDescriptor[]
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

export function effortsOf(choice: ModelChoice): string[] {
  return choice.group?.effortLevels ?? choice.model?.effortLevels ?? []
}

export function pickGroup<Draft extends ModelChoice>(
  draft: Draft,
  group: ModelGroupDescriptor,
  effort: string | null = group.defaultEffort,
): Draft {
  return {
    ...draft,
    provider: '',
    model: null,
    group,
    effort: effort != null && group.effortLevels.includes(effort)
      ? effort
      : null,
  }
}

// An empty catalog of providers still offers its groups.
export function initialChoice(catalog: ModelCatalog): ModelChoice {
  const first = catalog.providers[0]
  const group = catalog.groups[0]
  if (first == null && group != null) {
    return pickGroup({ provider: '', model: null, effort: null }, group)
  }
  const model = defaultModelOf(first)
  return { provider: first?.id ?? '', model, effort: defaultEffortOf(model) }
}

// Members keep their own allowances, so a group names them rather than
// adding their quotas together.
export function groupMembersLine(group: ModelGroupDescriptor): string {
  const members = group.members.map((member) =>
    `${member.id} (${member.provider}/${member.model})`
  ).join(', ')
  return `Runs on one member at a time: ${members}.`
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
  groups: ModelGroupDescriptor[] = [],
): SessionDraft {
  if (template == null) return { ...draft, template: null }
  if (template.modelGroup != null) {
    const group = groups.find((g) => g.id === template.modelGroup)
    if (group == null) {
      return {
        ...draft,
        template: template.name,
        group: null,
        provider: '',
        model: null,
        effort: null,
      }
    }
    return pickGroup(
      { ...draft, template: template.name },
      group,
      template.effort ?? group.defaultEffort,
    )
  }
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
    group: null,
    provider: provider.id,
    model,
    effort: offered ? effort : defaultEffortOf(model),
  }
}

// A template's group the catalog no longer offers stays unpicked: the person
// picks a model before the session can be created.
export function templateUnmatched(
  template: SessionTemplateDescriptor | null,
  groups: ModelGroupDescriptor[],
): Unmatched | undefined {
  const group = template?.modelGroup
  if (group == null || groups.some((g) => g.id === group)) return undefined
  return { model: null, effort: null, group }
}

export function draftReady(draft: SessionDraft): boolean {
  return draft.title.trim() !== '' &&
    (draft.group != null || (draft.provider !== '' && draft.model != null))
}

export function sessionCreateInput(draft: SessionDraft): DraftResult {
  const title = draft.title.trim()
  if (title === '') return { error: 'a title is required' }
  const effort = draft.effort
  const target = draft.group != null
    ? { modelGroup: draft.group.id }
    : draft.provider !== '' && draft.model != null
    ? { provider: draft.provider, model: draft.model.id }
    : null
  if (target == null) return { error: 'pick a model' }
  return {
    input: {
      title,
      kind: 'agent',
      ...target,
      ...(effort == null || effort === '' ? {} : { effort }),
      ...(draft.template == null ? {} : { template: draft.template }),
    },
  }
}
