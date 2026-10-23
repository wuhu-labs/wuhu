import { useState } from 'react'
import { useLocation, useNavigate } from 'react-router'
import { GlassMenu } from '@wuhu/ui'
import { SessionAvatar } from '~/components/space-sidebar'
import { ModalDialog } from '~/components/modal-dialog'
import { sessionHref } from '~/lib/links'
import type { SessionRecord } from '~/lib/session-model'
import { ApiError, errorMessage } from '~/sdk/errors'
import { archiveSession } from '~/sdk/session'
import { SessionRestartDialog } from '~/components/session-restart'

export function SessionMenu({ record }: { record: SessionRecord }) {
  const navigate = useNavigate()
  const location = useLocation()
  const transcriptSelected =
    new URLSearchParams(location.search).get('view') === 'transcript'
  const [action, setAction] = useState<'restart' | 'archive' | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [archiveConflict, setArchiveConflict] = useState(false)
  const choose = (next: typeof action) => {
    setError(null)
    setArchiveConflict(false)
    setAction(next)
  }
  const confirmArchive = async () => {
    setBusy(true)
    setError(null)
    try {
      await archiveSession(record, { force: archiveConflict })
      setAction(null)
    } catch (failure) {
      setArchiveConflict(failure instanceof ApiError && failure.status === 409)
      setError(errorMessage(failure))
    } finally {
      setBusy(false)
    }
  }
  return (
    <>
      <GlassMenu
        label='Agent menu'
        lead={<SessionAvatar session={record} size={26} />}
        sections={[
          [{
            label: 'Transcript',
            onSelect: () => {
              void navigate(
                sessionHref(record.id, record.group, 'transcript'),
                { replace: transcriptSelected },
              )
            },
          }],
          [{
            label: 'Start over',
            disabled: record.lifecycle === 'archived',
            onSelect: () => choose('restart'),
          }, {
            label: 'Archive',
            disabled: record.lifecycle === 'archived',
            onSelect: () => choose('archive'),
          }],
        ]}
      >
        {record.title}
      </GlassMenu>
      <SessionRestartDialog
        open={action === 'restart'}
        record={record}
        onClose={() => setAction(null)}
      />
      <ModalDialog
        open={action === 'archive'}
        title={`Archive ${record.title}?`}
        onClose={() => {
          if (!busy) setAction(null)
        }}
      >
        <p>
          Archive this agent and its descendants. Running work requires a
          separate confirmation.
        </p>
        {error && <p className='wuhu-alert' role='alert'>{error}</p>}
        <div className='wuhu-document-actions'>
          <button
            type='button'
            className='wuhu-quiet-button'
            disabled={busy}
            onClick={() => setAction(null)}
          >
            Cancel
          </button>
          <button
            type='button'
            className='wuhu-button'
            disabled={busy}
            onClick={() => void confirmArchive()}
          >
            {busy
              ? 'Working…'
              : archiveConflict
              ? 'Stop work and archive'
              : 'Archive'}
          </button>
        </div>
      </ModalDialog>
    </>
  )
}
