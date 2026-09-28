import { useEffect, useState } from 'react'
import { useOutletContext } from 'react-router'
import { KindChoice, ModelControls } from '~/components/session-create'
import { ModalDialog } from '~/components/modal-dialog'
import type { SpaceContext } from '~/routes/space'
import {
  defaultEffortOf,
  defaultModelOf,
  selectableProviders,
} from '~/lib/session-create'
import {
  emptyTemplateDraft,
  templateBrief,
  templateDirectory,
  type TemplateDraft,
  templateManifest,
  templateNameError,
  templateReady,
} from '~/lib/templates'
import type { ProviderDescriptor } from '~/lib/contract.gen'
import { fetchProviders } from '~/sdk/providers'
import { errorMessage } from '~/sdk/errors'

function CreateForm({
  providers,
  taken,
  onCancel,
  onCreated,
}: {
  providers: ProviderDescriptor[]
  taken: (name: string) => boolean
  onCancel: () => void
  onCreated: () => void
}) {
  const { client } = useOutletContext<SpaceContext>()
  const [draft, setDraft] = useState<TemplateDraft>(() => {
    const first = providers[0]
    const model = defaultModelOf(first)
    return {
      ...emptyTemplateDraft,
      provider: first?.id ?? '',
      model,
      effort: defaultEffortOf(model),
    }
  })
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const ready = templateReady(draft) && !submitting

  const submit = () => {
    if (!ready) return
    const invalid = templateNameError(draft.name)
    if (invalid != null) {
      setError(invalid)
      return
    }
    if (taken(draft.name)) {
      setError(`A template named ${draft.name} already exists.`)
      return
    }
    const directory = templateDirectory(draft.name)
    setSubmitting(true)
    setError(null)
    client.write(`${directory}/template.json`, templateManifest(draft))
      .then(() => client.write(`${directory}/AGENTS.md`, templateBrief(draft)))
      .then(onCreated)
      .catch((failure: unknown) => {
        setSubmitting(false)
        setError(errorMessage(failure))
      })
  }

  return (
    <div className='wuhu-form'>
      <label className='wuhu-field wuhu-field-wide wuhu-field-mono'>
        <span>name</span>
        <input
          autoFocus
          placeholder='night-shift'
          value={draft.name}
          onChange={(event) =>
            setDraft({ ...draft, name: event.target.value.trim() })}
        />
      </label>
      <KindChoice
        value={draft.kind}
        onChange={(kind) => setDraft({ ...draft, kind })}
      />
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
      <label className='wuhu-field wuhu-field-wide'>
        <span>description</span>
        <input
          placeholder='One line, for the people picking it.'
          value={draft.description}
          onChange={(event) =>
            setDraft({ ...draft, description: event.target.value })}
        />
      </label>
      <label className='wuhu-field wuhu-field-wide'>
        <span>brief</span>
        <textarea
          placeholder='What this session is for, how it should work, what to read first…'
          value={draft.brief}
          onChange={(event) =>
            setDraft({ ...draft, brief: event.target.value })}
        />
      </label>
      {error && <p className='wuhu-alert'>{error}</p>}
      <div className='wuhu-form-actions'>
        <button type='button' className='wuhu-quiet-button' onClick={onCancel}>
          Cancel
        </button>
        <button
          type='button'
          className='wuhu-button'
          disabled={!ready}
          onClick={submit}
        >
          Create template
        </button>
      </div>
    </div>
  )
}

export function TemplateCreateDialog({
  open,
  taken,
  onClose,
  onCreated,
}: {
  open: boolean
  taken: (name: string) => boolean
  onClose: () => void
  onCreated: () => void
}) {
  const [providers, setProviders] = useState<ProviderDescriptor[] | null>(null)
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
    <ModalDialog open={open} title='New template' onClose={onClose}>
      {loadError && <p className='wuhu-alert'>{loadError}</p>}
      {!loadError && providers == null && (
        <p className='wuhu-muted'>Loading models…</p>
      )}
      {!loadError && providers != null && (
        <CreateForm
          providers={providers}
          taken={taken}
          onCancel={onClose}
          onCreated={onCreated}
        />
      )}
    </ModalDialog>
  )
}
