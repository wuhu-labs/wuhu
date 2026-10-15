import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router'
import { ModalDialog } from '~/components/modal-dialog'
import {
  agentTemplates,
  applyTemplate,
  defaultEffortOf,
  defaultModelOf,
  draftReady,
  effortsOf,
  emptyDraft,
  groupMembersLine,
  initialChoice,
  type ModelCatalog,
  type ModelChoice,
  modelOf,
  pickGroup,
  sessionCreateInput,
  type SessionDraft,
  type SessionKind,
  templateUnmatched,
  type Unmatched,
} from '~/lib/session-create'
import type {
  ModelGroupDescriptor,
  ProviderDescriptor,
  SessionTemplateDescriptor,
} from '~/lib/contract.gen'
import { fetchModelCatalog } from '~/sdk/providers'
import { fetchTemplates } from '~/sdk/templates'
import { errorMessage } from '~/sdk/errors'
import { type CreatedSession, screens, sessionHref } from '~/lib/links'
import { createSession } from '~/sdk/session'
import { groupLabel } from '~/lib/groups'
import { useDirectory } from '~/lib/use-directory'

const kinds: { kind: SessionKind; label: string; blurb: string }[] = [
  {
    kind: 'agent',
    label: 'Agent',
    blurb: 'A persistent identity with a public box people post into.',
  },
  {
    kind: 'task',
    label: 'Task',
    blurb: 'One job, driven like Claude Code, done when it is done.',
  },
]

export function KindChoice({
  value,
  onChange,
}: {
  value: SessionKind | null
  onChange: (kind: SessionKind) => void
}) {
  return (
    <div
      className='wuhu-kind-choice'
      role='radiogroup'
      aria-label='Session kind'
    >
      {kinds.map((option) => (
        <button
          key={option.kind}
          type='button'
          role='radio'
          aria-checked={value === option.kind}
          data-selected={value === option.kind}
          className='wuhu-kind-option'
          onClick={() => onChange(option.kind)}
        >
          <strong>{option.label}</strong>
          <span>{option.blurb}</span>
        </button>
      ))}
    </div>
  )
}

// `unmatched` names what the draft holds that the catalog does not offer; it
// shows as a disabled, selected option until something else is picked. Model
// groups share the provider menu: a group stands in for provider and model.
export function ModelControls<Draft extends ModelChoice>({
  providers,
  groups = [],
  draft,
  unmatched,
  onChange,
}: {
  providers: ProviderDescriptor[]
  groups?: ModelGroupDescriptor[]
  draft: Draft
  unmatched?: Unmatched
  onChange: (draft: Draft) => void
}) {
  const group = draft.group ?? null
  const selected = group == null
    ? providers.find((p) => p.id === draft.provider)
    : undefined
  const efforts = effortsOf(draft)
  const unmatchedGroup = group == null && draft.provider === ''
    ? unmatched?.group ?? null
    : null
  const unmatchedModel = group == null && draft.model == null
    ? unmatched?.model
    : null
  const unmatchedEffort = draft.effort == null ? unmatched?.effort : null
  const defaultEffort = group?.defaultEffort ?? draft.model?.defaultEffort
  const target = group != null
    ? groupValue(group.id)
    : unmatchedGroup != null
    ? groupValue(unmatchedGroup)
    : draft.provider
  return (
    <>
      <div className='wuhu-field-row'>
        <label className='wuhu-field'>
          <span>{group == null ? 'provider' : 'model group'}</span>
          <select
            value={target}
            onChange={(event) => {
              const value = event.target.value
              const picked = groups.find((g) => groupValue(g.id) === value)
              if (picked != null) {
                onChange(pickGroup(draft, picked))
                return
              }
              const provider = providers.find((p) => p.id === value)
              const model = defaultModelOf(provider)
              onChange({
                ...draft,
                group: null,
                provider: value,
                model,
                effort: defaultEffortOf(model),
              })
            }}
          >
            {group == null && unmatchedGroup != null && (
              <option value={target} disabled>{unmatchedGroup}</option>
            )}
            {group == null && unmatchedGroup == null && selected == null && (
              <option value={draft.provider} disabled>
                {draft.provider || '—'}
              </option>
            )}
            {providers.map((provider) => (
              <option key={provider.id} value={provider.id}>
                {provider.id}
              </option>
            ))}
            {groups.length > 0 && (
              <optgroup label='Model groups'>
                {groups.map((option) => (
                  <option key={option.id} value={groupValue(option.id)}>
                    {option.id}
                  </option>
                ))}
              </optgroup>
            )}
          </select>
        </label>
        {(unmatchedModel != null || (selected?.models.length ?? 0) > 0) && (
          <label className='wuhu-field'>
            <span>model</span>
            <select
              value={draft.model?.id ?? unmatchedModel ?? ''}
              onChange={(event) => {
                const model = modelOf(selected, event.target.value)
                onChange({ ...draft, model, effort: defaultEffortOf(model) })
              }}
            >
              {unmatchedModel != null && (
                <option value={unmatchedModel} disabled>
                  {unmatchedModel}
                </option>
              )}
              {selected?.models.map((model) => (
                <option key={model.id} value={model.id}>{model.id}</option>
              ))}
            </select>
          </label>
        )}
        {efforts.length > 0 && (
          <label className='wuhu-field'>
            <span>effort</span>
            <select
              value={draft.effort ?? unmatchedEffort ?? ''}
              onChange={(event) =>
                onChange({
                  ...draft,
                  effort: event.target.value === '' ? null : event.target.value,
                })}
            >
              {unmatchedEffort != null && (
                <option value={unmatchedEffort} disabled>
                  {unmatchedEffort}
                </option>
              )}
              {defaultEffort == null && <option value=''>—</option>}
              {efforts.map((effort) => <option key={effort}>{effort}</option>)}
            </select>
          </label>
        )}
      </div>
      {group != null && <p className='wuhu-muted'>{groupMembersLine(group)}</p>}
    </>
  )
}

// Group options live in the provider menu under a prefix no provider id has.
function groupValue(id: string): string {
  return `group:${id}`
}

function CreateForm({
  catalog,
  groups,
  defaultGroup,
  onDone,
}: {
  catalog: ModelCatalog
  groups: string[]
  defaultGroup: string
  onDone: () => void
}) {
  const navigate = useNavigate()
  const directory = useDirectory()
  const [group, setGroup] = useState(defaultGroup)
  const [templates, setTemplates] = useState<
    ReadonlyMap<string, SessionTemplateDescriptor[]>
  >(new Map())
  const { providers } = catalog
  const [draft, setDraft] = useState<SessionDraft>(() => ({
    ...emptyDraft,
    ...initialChoice(catalog),
  }))
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (templates.has(group)) return
    let cancelled = false
    fetchTemplates(group).catch((): SessionTemplateDescriptor[] => []).then(
      (found) => {
        if (!cancelled) {
          setTemplates((current) =>
            new Map(current).set(group, agentTemplates(found))
          )
        }
      },
    )
    return () => {
      cancelled = true
    }
  }, [group, templates])
  const offered = templates.get(group) ?? []

  const ready = draftReady(draft) && !submitting
  const template = offered.find((t) => t.name === draft.template)
  const unmatched = templateUnmatched(template ?? null, catalog.groups)

  const submit = () => {
    if (!ready) return
    const result = sessionCreateInput(draft)
    if ('error' in result) {
      setError(result.error)
      return
    }
    setSubmitting(true)
    setError(null)
    createSession(result.input, group)
      .then((output) => {
        onDone()
        void navigate(sessionHref(output.id, group), {
          state: { created: output.id } satisfies CreatedSession,
        })
      })
      .catch((failure: unknown) => {
        setSubmitting(false)
        setError(errorMessage(failure))
      })
  }

  return (
    <div className='wuhu-form'>
      <label className='wuhu-field wuhu-field-wide'>
        <span>group</span>
        <select
          value={group}
          onChange={(event) => {
            setGroup(event.target.value)
            setDraft(applyTemplate(draft, null, providers))
          }}
        >
          {groups.map((option) => (
            <option key={option} value={option}>
              {groupLabel(option, directory)}
            </option>
          ))}
        </select>
      </label>
      {offered.length > 0 && (
        <div className='wuhu-template-pick'>
          <label className='wuhu-field wuhu-field-wide'>
            <span>template</span>
            <select
              value={draft.template ?? ''}
              onChange={(event) =>
                setDraft(applyTemplate(
                  draft,
                  offered.find((t) => t.name === event.target.value) ?? null,
                  providers,
                  catalog.groups,
                ))}
            >
              <option value=''>— none —</option>
              {offered.map((option) => (
                <option key={option.name} value={option.name}>
                  {option.name}
                </option>
              ))}
            </select>
          </label>
          <p className='wuhu-muted'>
            {template?.description ? `${template.description} ` : ''}
            <Link to={screens.templates} onClick={onDone}>
              Manage templates
            </Link>
          </p>
        </div>
      )}
      <label className='wuhu-field wuhu-field-wide'>
        <span>title</span>
        <input
          autoFocus
          placeholder='What is this session for?'
          value={draft.title}
          onChange={(event) =>
            setDraft({ ...draft, title: event.target.value })}
          onKeyDown={(event) => {
            if (event.key === 'Enter') submit()
          }}
        />
      </label>
      {providers.length === 0 && catalog.groups.length === 0 && (
        <p className='wuhu-muted'>No models are configured.</p>
      )}
      {(providers.length > 0 || catalog.groups.length > 0) && (
        <ModelControls
          providers={providers}
          groups={catalog.groups}
          draft={draft}
          unmatched={unmatched}
          onChange={setDraft}
        />
      )}
      {unmatched?.group != null && draft.group == null &&
        draft.provider === '' && (
        <p className='wuhu-alert'>
          {unmatched.group} is no longer offered; pick a model.
        </p>
      )}
      {error && <p className='wuhu-alert'>{error}</p>}
      <div className='wuhu-form-actions'>
        <button type='button' className='wuhu-quiet-button' onClick={onDone}>
          Cancel
        </button>
        <button
          type='button'
          className='wuhu-button'
          disabled={!ready}
          onClick={submit}
        >
          Create agent
        </button>
      </div>
    </div>
  )
}

export function SessionCreateDialog({
  open,
  groups,
  group,
  onClose,
}: {
  open: boolean
  groups: string[]
  group: string
  onClose: () => void
}) {
  const [catalog, setCatalog] = useState<ModelCatalog | null>(null)
  const [loadError, setLoadError] = useState<string | null>(null)

  useEffect(() => {
    if (!open || catalog != null) return
    let cancelled = false
    fetchModelCatalog().then(
      (found) => {
        if (!cancelled) setCatalog(found)
      },
      (failure: unknown) => {
        if (!cancelled) setLoadError(errorMessage(failure))
      },
    )
    return () => {
      cancelled = true
    }
  }, [open, catalog])

  return (
    <ModalDialog open={open} title='New agent' onClose={onClose}>
      {loadError && <p className='wuhu-alert'>{loadError}</p>}
      {!loadError && catalog == null && (
        <p className='wuhu-muted'>Loading models…</p>
      )}
      {!loadError && catalog != null && (
        <CreateForm
          catalog={catalog}
          groups={groups}
          defaultGroup={group}
          onDone={onClose}
        />
      )}
    </ModalDialog>
  )
}
