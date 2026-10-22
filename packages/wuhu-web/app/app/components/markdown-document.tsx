import { type ReactNode, useCallback, useEffect, useRef, useState } from 'react'
import type { ReadOutput } from '~/lib/contract.gen'
import {
  applySync,
  type DocumentState,
  documentState,
  editDocument,
  keepLocal,
  remoteDocument,
  useRemote,
} from '~/lib/document-sync'
import { editableDocument, joinEditable } from '~/lib/frontmatter'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'
import { DocumentEditor } from './document-editor'

const saveDelayMs = 800

// A Markdown page: the breadcrumb row with Edit/Done on its right, then the
// document, read or edited in place.
export function MarkdownDocument({
  client,
  path,
  initial,
  breadcrumb,
}: {
  client: SpaceClient
  path: string
  initial: ReadOutput
  breadcrumb: ReactNode
}) {
  const [editing, setEditing] = useState(false)
  const [state, setState] = useState(() => documentState(initial))
  const stateRef = useRef(state)
  const saving = useRef(false)
  // No unmounted guard: React drops setState on unmounted components silently,
  // and a ref-based guard breaks under StrictMode's dev double-mount (the
  // cleanup runs once and nothing ever sets it back).
  const update = useCallback(
    (body: (current: DocumentState) => DocumentState) => {
      setState((current) => {
        const next = body(current)
        stateRef.current = next
        return next
      })
    },
    [],
  )

  const persist = useCallback(async () => {
    if (saving.current) return
    const snapshot = stateRef.current
    if (
      snapshot.phase === 'conflict' || snapshot.draft === snapshot.base.content
    ) {
      return
    }
    saving.current = true
    update((current) => ({ ...current, phase: 'saving', error: undefined }))
    try {
      const output = await client.sync(
        path,
        snapshot.base.token,
        snapshot.draft,
      )
      update((current) => applySync(current, snapshot.draft, output))
    } catch (failure: unknown) {
      update((current) => ({
        ...current,
        phase: 'error',
        error: errorMessage(failure),
      }))
    } finally {
      saving.current = false
    }
  }, [client, path, update])

  useEffect(() => {
    if (state.phase !== 'dirty') return
    const timer = setTimeout(() => void persist(), saveDelayMs)
    return () => clearTimeout(timer)
  }, [persist, state.draft, state.phase])

  useEffect(() => {
    let cancelled = false
    const stop = client.read(path)(
      (read) => {
        if (cancelled) return
        update((current) =>
          current.phase === 'clean' || current.phase === 'error'
            ? remoteDocument(current, read)
            : current
        )
      },
      (failure: unknown) => {
        if (!cancelled) {
          update((current) => ({
            ...current,
            phase: 'error',
            error: errorMessage(failure),
          }))
        }
      },
    )
    return () => {
      cancelled = true
      stop()
    }
  }, [client, path, update])

  return (
    <section className='wuhu-document' data-wuhu-document={path}>
      <div className='wuhu-document-utility'>
        {breadcrumb}
        <button
          type='button'
          className='wuhu-document-edit'
          aria-pressed={editing}
          disabled={editing && state.phase === 'conflict'}
          onClick={() => {
            if (editing) void persist()
            setEditing(!editing)
          }}
        >
          {editing ? 'Done' : 'Edit'}
        </button>
      </div>
      {state.phase === 'error' && (
        <p className='wuhu-alert' role='alert'>
          {state.error ?? 'Save failed'}
        </p>
      )}
      {state.phase === 'conflict' && (
        <div className='wuhu-document-conflict' role='alert'>
          <strong>
            Another writer changed the same part of this document.
          </strong>
          <span>Your draft is safe. Choose which version should remain.</span>
          <div className='wuhu-document-actions'>
            <button
              type='button'
              className='wuhu-quiet-button'
              onClick={() =>
                update(useRemote)}
            >
              Use changed version
            </button>
            <button
              type='button'
              className='wuhu-button'
              onClick={() =>
                update(keepLocal)}
            >
              Keep my version
            </button>
          </div>
        </div>
      )}
      <DocumentEditor
        initial={editableDocument(initial.content).body}
        remote={{
          revision: state.revision,
          body: editableDocument(state.draft).body,
        }}
        editable={editing}
        sourcePath={path}
        onChange={(body) =>
          update((current) =>
            editDocument(
              current,
              joinEditable(editableDocument(current.draft), body),
            )
          )}
      />
    </section>
  )
}
