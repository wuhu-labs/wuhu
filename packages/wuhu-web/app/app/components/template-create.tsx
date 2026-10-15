import { useEffect, useState } from 'react'
import { useOutletContext } from 'react-router'
import { KindChoice, ModelControls } from '~/components/session-create'
import { ModalDialog } from '~/components/modal-dialog'
import type { SpaceContext } from '~/routes/space'
import { initialChoice, type ModelCatalog } from '~/lib/session-create'
import {
  emptyTemplateDraft,
  templateBrief,
  templateDirectory,
  type TemplateDraft,
  templateManifest,
  templateNameError,
  templateReady,
} from '~/lib/templates'
import { fetchModelCatalog } from '~/sdk/providers'
import { errorMessage } from '~/sdk/errors'

function CreateForm({
  catalog,
  taken,
  onCancel,
  onCreated,
}: {
  catalog: ModelCatalog
  taken: (name: string) => boolean
  onCancel: () => void
  onCreated: () => void
}) {
  const { client } = useOutletContext<SpaceContext>()
  const { providers, groups } = catalog
  const [draft, setDraft] = useState<TemplateDraft>(() => ({
    ...emptyTemplateDraft,
    ...initialChoice(catalog),
  }))
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
      {providers.length === 0 && groups.length === 0 && (
        <p className='wuhu-muted'>No models are configured.</p>
      )}
      {(providers.length > 0 || groups.length > 0) && (
        <ModelControls
          providers={providers}
          groups={groups}
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
    <ModalDialog open={open} title='New template' onClose={onClose}>
      {loadError && <p className='wuhu-alert'>{loadError}</p>}
      {!loadError && catalog == null && (
        <p className='wuhu-muted'>Loading models…</p>
      )}
      {!loadError && catalog != null && (
        <CreateForm
          catalog={catalog}
          taken={taken}
          onCancel={onClose}
          onCreated={onCreated}
        />
      )}
    </ModalDialog>
  )
}
