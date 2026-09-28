import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router'
import { ModalDialog } from '~/components/modal-dialog'
import {
  agentTemplates,
  applyTemplate,
  defaultEffortOf,
  defaultModelOf,
  draftReady,
  emptyDraft,
  type ModelChoice,
  modelOf,
  selectableProviders,
  sessionCreateInput,
  type SessionDraft,
  type SessionKind,
  type Unmatched,
} from '~/lib/session-create'
import type {
  ProviderDescriptor,
  SessionTemplateDescriptor,
} from '~/lib/contract.gen'
import { fetchProviders } from '~/sdk/providers'
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
// shows as a disabled, selected option until something else is picked.
export function ModelControls<Draft extends ModelChoice>({
  providers,
  draft,
  unmatched,
  onChange,
}: {
  providers: ProviderDescriptor[]
  draft: Draft
  unmatched?: Unmatched
  onChange: (draft: Draft) => void
}) {
  const selected = providers.find((p) => p.id === draft.provider)
  const efforts = draft.model?.effortLevels ?? []
  const unmatchedModel = draft.model == null ? unmatched?.model : null
  const unmatchedEffort = draft.effort == null ? unmatched?.effort : null
  return (
    <div className='wuhu-field-row'>
      <label className='wuhu-field'>
        <span>provider</span>
        <select
          value={draft.provider}
          onChange={(event) => {
            const provider = providers.find((p) => p.id === event.target.value)
            const model = defaultModelOf(provider)
            onChange({
              ...draft,
              provider: event.target.value,
              model,
              effort: defaultEffortOf(model),
            })
          }}
        >
          {selected == null && (
            <option value={draft.provider} disabled>
              {draft.provider || '—'}
            </option>
          )}
          {providers.map((provider) => (
            <option key={provider.id} value={provider.id}>
              {provider.id}
            </option>
          ))}
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
              <option value={unmatchedModel} disabled>{unmatchedModel}</option>
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
            {draft.model?.defaultEffort == null && <option value=''>—</option>}
            {efforts.map((effort) => <option key={effort}>{effort}</option>)}
          </select>
        </label>
      )}
    </div>
  )
}

function CreateForm({
  providers,
  groups,
  defaultGroup,
  onDone,
}: {
  providers: ProviderDescriptor[]
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
  const [draft, setDraft] = useState<SessionDraft>(() => {
    const first = providers[0]
    const model = defaultModelOf(first)
    return {
      ...emptyDraft,
      provider: first?.id ?? '',
      model,
      effort: defaultEffortOf(model),
    }
  })
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
      {providers.length === 0 && (
        <p className='wuhu-muted'>No models are configured.</p>
      )}
      {providers.length > 0 && (
        <ModelControls
          providers={providers}
          draft={draft}
          onChange={setDraft}
        />
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
  const [providers, setProviders] = useState<ProviderDescriptor[] | null>(
    null,
  )
  const [loadError, setLoadError] = useState<string | null>(null)

  useEffect(() => {
    if (!open || providers != null) return
    let cancelled = false
    fetchProviders().then(
      (found) => {
        if (!cancelled) setProviders(selectableProviders(found))
      },
      (failure: unknown) => {
        if (!cancelled) setLoadError(errorMessage(failure))
      },
    )
    return () => {
      cancelled = true
    }
  }, [open, providers])

  return (
    <ModalDialog open={open} title='New agent' onClose={onClose}>
      {loadError && <p className='wuhu-alert'>{loadError}</p>}
      {!loadError && providers == null && (
        <p className='wuhu-muted'>Loading models…</p>
      )}
      {!loadError && providers != null && (
        <CreateForm
          providers={providers}
          groups={groups}
          defaultGroup={group}
          onDone={onClose}
        />
      )}
    </ModalDialog>
  )
}
