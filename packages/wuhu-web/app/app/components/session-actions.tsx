import { useEffect, useState } from 'react'
import type { MenuAction } from '@wuhu/ui'
import { ModalDialog } from '~/components/modal-dialog'
import { ModelControls } from '~/components/session-create'
import { ShareActions } from '~/components/share-actions'
import type { ProviderDescriptor } from '~/lib/contract.gen'
import {
  canCompose,
  type SessionAction,
  sessionActions,
  sessionCapability,
} from '~/lib/session-capability'
import {
  type ModelChoice,
  selectableProviders,
  type Unmatched,
} from '~/lib/session-create'
import type { SessionRecord } from '~/lib/session-model'
import { adoptSpec, restartInput } from '~/lib/session-restart'
import { errorMessage } from '~/sdk/errors'
import { fetchProviders } from '~/sdk/providers'
import {
  archiveSession,
  browserTimezone,
  compactSession,
  restartSession,
  type SessionAddress,
  unarchiveSession,
} from '~/sdk/session'

export function SessionActions(
  { session, record }: {
    session: SessionAddress
    record: SessionRecord | null
  },
) {
  const capability = sessionCapability(record)
  const addressable = canCompose(capability)
  const [sheet, setSheet] = useState<'compact' | 'restart' | null>(null)
  const [failure, setFailure] = useState<
    { action: string; reason: string } | null
  >(null)
  const close = () => setSheet(null)

  const lifecycle = (
    action: string,
    change: (session: SessionAddress) => Promise<void>,
  ) =>
    change(session).catch((failed: unknown) =>
      setFailure({ action, reason: errorMessage(failed) })
    )

  const items: Record<SessionAction, MenuAction> = {
    compact: {
      label: 'Compact',
      icon: 'compact',
      onSelect: () => setSheet('compact'),
    },
    restart: {
      label: 'Start over…',
      icon: 'restart',
      danger: true,
      onSelect: () => setSheet('restart'),
    },
    archive: {
      label: 'Archive',
      icon: 'archive',
      danger: true,
      onSelect: () => void lifecycle('Archive', archiveSession),
    },
    unarchive: {
      label: 'Unarchive',
      icon: 'unarchive',
      onSelect: () => void lifecycle('Unarchive', unarchiveSession),
    },
  }

  return (
    <>
      <ShareActions
        menu={sessionActions(capability).map((action) => items[action])}
      />
      <ModalDialog open={sheet === 'compact'} title='Compact' onClose={close}>
        <CompactForm
          session={session}
          addressable={addressable}
          onDone={close}
        />
      </ModalDialog>
      <ModalDialog
        open={sheet === 'restart'}
        title='Start over'
        onClose={close}
      >
        {record && (
          <RestartForm
            record={record}
            addressable={addressable}
            onDone={close}
          />
        )}
      </ModalDialog>
      <ModalDialog
        open={failure != null}
        title={failure == null ? '' : `${failure.action} failed`}
        onClose={() => setFailure(null)}
      >
        <p className='wuhu-alert'>{failure?.reason}</p>
        <div className='wuhu-form-actions'>
          <button
            type='button'
            className='wuhu-button'
            onClick={() => setFailure(null)}
          >
            OK
          </button>
        </div>
      </ModalDialog>
    </>
  )
}

function CompactForm(
  { session, addressable, onDone }: {
    session: SessionAddress
    addressable: boolean
    onDone: () => void
  },
) {
  const [instructions, setInstructions] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const run = () => {
    setBusy(true)
    setError(null)
    compactSession(session, instructions).then(
      onDone,
      (failure: unknown) => {
        setBusy(false)
        setError(errorMessage(failure))
      },
    )
  }

  return (
    <div className='wuhu-form'>
      <p className='wuhu-muted'>
        Folds the context at the session's next quiet point.
      </p>
      {addressable && (
        <label className='wuhu-field wuhu-field-wide'>
          <span>instructions</span>
          <textarea
            autoFocus
            placeholder='what to keep (optional)'
            value={instructions}
            onChange={(event) => setInstructions(event.target.value)}
          />
        </label>
      )}
      {error && <p className='wuhu-alert'>{error}</p>}
      <div className='wuhu-form-actions'>
        <button type='button' className='wuhu-quiet-button' onClick={onDone}>
          Cancel
        </button>
        <button
          type='button'
          className='wuhu-button'
          disabled={busy}
          onClick={run}
        >
          Compact
        </button>
      </div>
    </div>
  )
}

function RestartForm(
  { record, addressable, onDone }: {
    record: SessionRecord
    addressable: boolean
    onDone: () => void
  },
) {
  const [adopted, setAdopted] = useState<
    {
      providers: ProviderDescriptor[]
      choice: ModelChoice
      unmatched: Unmatched
    } | null
  >(null)
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    fetchProviders().then(
      (found) => {
        if (cancelled) return
        const providers = selectableProviders(found)
        setAdopted({ providers, ...adoptSpec(providers, record.spec) })
      },
      (failure: unknown) => {
        if (!cancelled) setError(errorMessage(failure))
      },
    )
    return () => {
      cancelled = true
    }
  }, [])

  const input = adopted &&
    restartInput(adopted.choice, record.spec, message, browserTimezone())
  const run = () => {
    if (input == null) return
    setBusy(true)
    setError(null)
    restartSession(record, input).then(onDone, (failure: unknown) => {
      setBusy(false)
      setError(errorMessage(failure))
    })
  }

  return (
    <div className='wuhu-form'>
      <p className='wuhu-muted'>
        {addressable
          ? "Keeps this session's id, box, DMs and home folder. Wipes the transcript and starts a fresh generation."
          : "Keeps this task's id, DMs and home folder. Wipes the transcript and starts a fresh generation."}
      </p>
      {adopted == null && error == null && (
        <p className='wuhu-muted'>Loading models…</p>
      )}
      {adopted != null && (
        <ModelControls
          providers={adopted.providers}
          draft={adopted.choice}
          unmatched={adopted.unmatched}
          onChange={(choice) =>
            setAdopted({
              ...adopted,
              choice,
              unmatched: { model: null, effort: null },
            })}
        />
      )}
      {adopted?.unmatched.model != null && (
        <p className='wuhu-alert'>
          {adopted.unmatched.model} is no longer offered; pick a model.
        </p>
      )}
      {adopted?.unmatched.effort != null && (
        <p className='wuhu-muted'>
          {adopted.unmatched.effort}{' '}
          is no longer offered for this model; it stays as it is unless you pick
          another.
        </p>
      )}
      {addressable && (
        <label className='wuhu-field wuhu-field-wide'>
          <span>opening message</span>
          <textarea
            placeholder='optional — posted into the fresh generation'
            value={message}
            onChange={(event) => setMessage(event.target.value)}
          />
        </label>
      )}
      {error && <p className='wuhu-alert'>{error}</p>}
      <div className='wuhu-form-actions'>
        <button type='button' className='wuhu-quiet-button' onClick={onDone}>
          Cancel
        </button>
        <button
          type='button'
          className='wuhu-button wuhu-button-danger'
          disabled={busy || input == null}
          onClick={run}
        >
          Start over
        </button>
      </div>
    </div>
  )
}
