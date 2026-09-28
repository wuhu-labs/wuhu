import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router'
import { fileHref } from '~/lib/links'
import { groupLabel } from '~/lib/groups'
import { newDocumentPath } from '~/lib/new-document'
import { useDirectory } from '~/lib/use-directory'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'

export function NewDocumentDialog({
  client,
  directory,
  exists,
  onClose,
}: {
  client: SpaceClient
  directory: string | null
  exists: (path: string) => boolean
  onClose: () => void
}) {
  const navigate = useNavigate()
  const people = useDirectory()
  const dialog = useRef<HTMLDialogElement>(null)
  const [name, setName] = useState('')
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const open = directory != null

  useEffect(() => {
    const el = dialog.current
    if (el == null) return
    if (open && !el.open) {
      setName('')
      setError(null)
      setCreating(false)
      el.showModal()
    }
    if (!open && el.open) el.close()
  }, [open])

  const submit = () => {
    if (directory == null || creating) return
    const resolved = newDocumentPath(directory, name, exists)
    if ('error' in resolved) {
      setError(resolved.error)
      return
    }
    setCreating(true)
    setError(null)
    client.write(resolved.path, '').then(
      () => {
        onClose()
        void navigate(fileHref(resolved.path, client.group))
      },
      (failure: unknown) => {
        setCreating(false)
        setError(errorMessage(failure))
      },
    )
  }

  return (
    <dialog
      ref={dialog}
      className='wuhu-composer-dialog'
      aria-label='New document'
      onClose={onClose}
    >
      {open && (
        <div className='wuhu-composer-dialog-body'>
          <hgroup className='wuhu-heading'>
            <h2 className='wuhu-dialog-title'>
              New document in {directory === '/' ? 'the space root' : directory}
            </h2>
            <p className='wuhu-subtitle'>
              {groupLabel(client.group, people)}
            </p>
          </hgroup>
          <div className='wuhu-form'>
            <label className='wuhu-field wuhu-field-wide'>
              <span>name</span>
              <input
                autoFocus
                placeholder='meeting-notes'
                value={name}
                onChange={(event) => setName(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') submit()
                }}
              />
            </label>
            {error && <p className='wuhu-alert'>{error}</p>}
            <div className='wuhu-form-actions'>
              <button
                type='button'
                className='wuhu-quiet-button'
                onClick={onClose}
              >
                Cancel
              </button>
              <button
                type='button'
                className='wuhu-button'
                disabled={name.trim() === '' || creating}
                onClick={submit}
              >
                Create document
              </button>
            </div>
          </div>
        </div>
      )}
    </dialog>
  )
}
