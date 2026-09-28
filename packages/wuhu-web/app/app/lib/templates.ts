import type { SessionTemplateDescriptor } from './contract.gen.ts'
import type { ModelChoice, SessionKind } from './session-create.ts'

export interface TemplateDraft extends ModelChoice {
  name: string
  kind: SessionKind | null
  description: string
  brief: string
}

export const emptyTemplateDraft: TemplateDraft = {
  name: '',
  kind: null,
  provider: '',
  model: null,
  effort: null,
  description: '',
  brief: '',
}

export function templateNameError(name: string): string | null {
  if (name === '') return 'Name the template.'
  if (!/^[a-z0-9-]+$/.test(name)) {
    return 'A template name is lowercase letters, digits and dashes.'
  }
  return null
}

export function templateDirectory(name: string): string {
  return `/templates/${name}`
}

export function templateReady(draft: TemplateDraft): boolean {
  return templateNameError(draft.name) == null && draft.kind != null &&
    draft.provider !== ''
}

export function templateManifest(draft: TemplateDraft): string {
  const description = draft.description.trim()
  const model = draft.model
  const effort = draft.effort
  const manifest = {
    ...(draft.kind == null ? {} : { kind: draft.kind }),
    ...(description === '' ? {} : { description }),
    ...(draft.provider === '' ? {} : { provider: draft.provider }),
    ...(model == null ? {} : { model: model.id }),
    ...(effort == null || effort === '' ? {} : { effort }),
  }
  return `${JSON.stringify(manifest, null, 2)}\n`
}

export function templateBrief(draft: TemplateDraft): string {
  const brief = draft.brief.trim()
  if (brief === '') return `# ${draft.name}\n`
  return `${brief}\n`
}

export function templateLine(template: SessionTemplateDescriptor): string {
  return [template.provider, template.model, template.effort]
    .filter((part): part is string => part != null && part !== '')
    .join(' · ')
}
