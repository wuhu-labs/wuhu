import { useCallback, useEffect, useRef, useState } from 'react'
import type { MutationEvent, ReadOutput } from '~/lib/contract.gen'
import {
  applySync,
  type DocumentState,
  documentState,
  editDocument,
  keepLocal,
  useRemote,
} from '~/lib/document-sync'
import { editableDocument, joinEditable } from '~/lib/frontmatter'
import { useObserve } from '~/lib/use-observe'
import type { SpaceClient } from '~/sdk/client'
import { errorMessage } from '~/sdk/errors'
import { globSubscription } from '~/sdk/subscriptions'
import { DocumentEditor } from './document-editor'

const saveDelayMs = 800

function latestRevision(current: number, event: MutationEvent): number {
  return Math.max(current, event.rev)
}

export function MarkdownDocument({
  client,
  path,
  initial,
}: {
  client: SpaceClient
  path: string
  initial: ReadOutput
}) {
  const [editing, setEditing] = useState(false)
  const [state, setState] = useState(() => documentState(initial))
  const stateRef = useRef(state)
  const saving = useRef(false)
  const handledRevision = useRef(0)
  const observed = useObserve(
    globSubscription(client, path, 0),
    latestRevision,
    0,
  ).data

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
    if (observed <= handledRevision.current || state.phase === 'conflict') {
      return
    }
    handledRevision.current = observed
    if (state.phase === 'dirty') {
      void persist()
      return
    }
    if (state.phase === 'saving') return
    let cancelled = false
    client.read(path).then(
      (read) => {
        if (cancelled) return
        update((current) =>
          current.phase === 'clean' || current.phase === 'error'
            ? documentState(read)
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
    }
  }, [client, observed, path, persist, state.phase, update])

  // The status line earns its ink only while editing or in trouble; a clean
  // document reads as a document, not as a save indicator.
  const status = editing || state.phase !== 'clean' ? statusText(state) : ''
  return (
    <section className='wuhu-document' data-wuhu-document={path}>
      <div className='wuhu-document-toolbar'>
        <span
          className={state.phase === 'error' || state.phase === 'conflict'
            ? 'wuhu-alert'
            : 'wuhu-muted'}
          data-wuhu-document-status={state.phase}
        >
          {status}
        </span>
        <div className='wuhu-document-actions'>
          {editing && (
            <button
              type='button'
              className='wuhu-quiet-button'
              disabled={state.phase === 'conflict'}
              onClick={() => {
                void persist()
                setEditing(false)
              }}
            >
              Save
            </button>
          )}
          <button
            type='button'
            className='wuhu-quiet-button'
            onClick={() => {
              if (editing) void persist()
              setEditing(!editing)
            }}
          >
            {editing ? 'Preview' : 'Edit'}
          </button>
        </div>
      </div>
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
        content={editableDocument(state.draft).body}
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

function statusText(state: DocumentState): string {
  switch (state.phase) {
    case 'clean':
      return 'Saved'
    case 'dirty':
      return 'Unsaved changes'
    case 'saving':
      return 'Saving…'
    case 'conflict':
      return 'Needs your choice'
    case 'error':
      return state.error ?? 'Save failed'
  }
}
