import { useEffect, useState } from 'react'
import { ModalDialog } from '~/components/modal-dialog'
import { ModelControls } from '~/components/session-create'
import {
  defaultEffortOf,
  type ModelCatalog,
  type ModelChoice,
  modelOf,
} from '~/lib/session-create'
import type { SessionRecord } from '~/lib/session-model'
import { errorMessage } from '~/sdk/errors'
import { fetchModelCatalog } from '~/sdk/providers'
import { browserTimezone, restartSession } from '~/sdk/session'

interface Submission {
  busy: boolean
  setBusy: (busy: boolean) => void
}

function RestartForm({ record, catalog, onClose, busy, setBusy }: Submission & {
  record: SessionRecord
  catalog: ModelCatalog
  onClose: () => void
}) {
  const [choice, setChoice] = useState<ModelChoice>(() => {
    const group = catalog.groups.find((g) => g.id === record.spec.modelGroup)
    const provider = record.spec.modelGroup == null
      ? record.spec.provider ?? ''
      : ''
    const model = modelOf(
      catalog.providers.find((p) => p.id === provider),
      record.spec.model ?? null,
    )
    const efforts = group?.effortLevels ?? model?.effortLevels ?? []
    const effort = record.spec.effort ?? group?.defaultEffort ??
      defaultEffortOf(model)
    return {
      group,
      provider,
      model,
      effort: effort != null && efforts.includes(effort) ? effort : null,
    }
  })
  const [message, setMessage] = useState('')
  const [error, setError] = useState<string | null>(null)
  const ready = choice.group != null ||
    (choice.provider !== '' && choice.model != null)
  const submit = async () => {
    if (!ready || busy) return
    setBusy(true)
    setError(null)
    try {
      await restartSession(record, {
        ...(choice.group != null
          ? { modelGroup: choice.group.id }
          : { provider: choice.provider, model: choice.model!.id }),
        ...(choice.effort == null ? {} : { effort: choice.effort }),
        ...(message.trim() === '' ? {} : { message: message.trim() }),
        timezone: browserTimezone(),
      })
      onClose()
    } catch (failure) {
      setError(errorMessage(failure))
    } finally {
      setBusy(false)
    }
  }
  return (
    <div className='wuhu-form'>
      <p>Start a new transcript generation. The box and its messages stay.</p>
      <fieldset disabled={busy}>
        <ModelControls
          providers={catalog.providers}
          groups={catalog.groups}
          draft={choice}
          unmatched={{
            model: record.spec.model ?? null,
            effort: record.spec.effort ?? null,
            group: record.spec.modelGroup ?? null,
          }}
          onChange={setChoice}
        />
        <label className='wuhu-field wuhu-field-wide'>
          <span>Opening message (optional)</span>
          <textarea
            value={message}
            onChange={(event) => setMessage(event.target.value)}
          />
        </label>
      </fieldset>
      {error && <p className='wuhu-alert' role='alert'>{error}</p>}
      <div className='wuhu-form-actions'>
        <button
          type='button'
          className='wuhu-quiet-button'
          disabled={busy}
          onClick={onClose}
        >
          Cancel
        </button>
        <button
          type='button'
          className='wuhu-button'
          disabled={busy || !ready}
          onClick={() => void submit()}
        >
          {busy ? 'Working…' : 'Start over'}
        </button>
      </div>
    </div>
  )
}

function RestartModels(
  { record, onClose, busy, setBusy }: Submission & {
    record: SessionRecord
    onClose: () => void
  },
) {
  const [catalog, setCatalog] = useState<ModelCatalog | null>(null)
  const [error, setError] = useState<string | null>(null)
  useEffect(() => {
    let cancelled = false
    fetchModelCatalog().then(
      (found) => {
        if (!cancelled) setCatalog(found)
      },
      (failure: unknown) => {
        if (!cancelled) setError(errorMessage(failure))
      },
    )
    return () => {
      cancelled = true
    }
  }, [])
  if (error != null) return <p className='wuhu-alert' role='alert'>{error}</p>
  if (catalog == null) return <p className='wuhu-muted'>Loading models…</p>
  return (
    <RestartForm
      record={record}
      catalog={catalog}
      onClose={onClose}
      busy={busy}
      setBusy={setBusy}
    />
  )
}

export function SessionRestartDialog({ open, record, onClose }: {
  open: boolean
  record: SessionRecord
  onClose: () => void
}) {
  const [busy, setBusy] = useState(false)
  return (
    <ModalDialog
      open={open}
      title={`Start ${record.title} over?`}
      onClose={() => {
        if (!busy) onClose()
      }}
    >
      {open && (
        <RestartModels
          record={record}
          onClose={onClose}
          busy={busy}
          setBusy={setBusy}
        />
      )}
    </ModalDialog>
  )
}
