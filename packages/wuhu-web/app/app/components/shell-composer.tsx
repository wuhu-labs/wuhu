import { useEffect, useRef, useState, useSyncExternalStore } from 'react'
import {
  ComposerButton,
  type ComposerSession,
  ComposerZone,
  SendButton,
} from '@wuhu/ui'
import { senderName } from '~/lib/directory'
import { useDirectory, useSessionTitles } from '~/lib/use-directory'
import { QuoteStrip } from '~/components/message-row'
import { PendingFiles } from '~/components/pending-files'
import { admitFiles } from '~/lib/attachments'
import { isComposerSendKey } from '~/lib/composer'
import {
  type Draft,
  type Drafts,
  restoreDraft,
  withDictation,
} from '~/lib/drafts'
import { useDictation } from '~/lib/use-dictation'
import { useDraft } from '~/lib/use-drafts'
import { errorMessage } from '~/sdk/errors'

export function ShellComposer({
  drafts,
  draftKey,
  pill,
  placeholder,
  dictate,
  onSend,
}: {
  drafts: Drafts
  draftKey: string
  pill?: ComposerSession
  placeholder: string
  dictate: boolean
  onSend: (draft: Draft) => Promise<unknown>
}) {
  const directory = useDirectory()
  const sessions = useSessionTitles()
  const draft = useDraft(drafts, draftKey)
  const [error, setError] = useState<string | null>(null)
  const [sending, setSending] = useState(false)
  const field = useRef<HTMLTextAreaElement>(null)
  const picker = useRef<HTMLInputElement>(null)
  const vaultFailures = useSyncExternalStore(
    drafts.subscribe,
    () => drafts.vaultFailures,
  )
  const seenFailures = useRef(vaultFailures)
  useEffect(() => {
    if (vaultFailures === seenFailures.current) return
    seenFailures.current = vaultFailures
    setError("Files won't survive a reload.")
  }, [vaultFailures])
  const dictation = useDictation(
    (spoken) => drafts.update(draftKey, (held) => withDictation(held, spoken)),
    setError,
  )

  // The field grows with its text, and refits when its width changes: a mic
  // button that appears late, or a narrower window, rewraps the same text.
  const fit = () => {
    const el = field.current!
    el.style.height = '0px'
    el.style.height = `${el.scrollHeight}px`
  }
  useEffect(fit, [draft.text])
  useEffect(() => {
    const observer = new ResizeObserver(fit)
    observer.observe(field.current!)
    return () => observer.disconnect()
  }, [])

  const attach = (incoming: File[]) => {
    const { admitted, refusal } = admitFiles(
      draft.files.map((held) => held.file),
      incoming,
    )
    setError(refusal)
    if (admitted.length === 0) return
    drafts.update(draftKey, (held) => ({
      ...held,
      files: [
        ...held.files,
        ...admitted.map((file) => ({ id: crypto.randomUUID(), file })),
      ],
    }))
  }

  const canSend = !sending &&
    (draft.text.trim() !== '' || draft.files.length > 0)
  // The draft leaves the composer when it is sent, so whatever is written
  // during the upload is kept, and a failure puts the draft back in front.
  const send = () => {
    if (!canSend) return
    const outgoing = draft
    setError(null)
    setSending(true)
    drafts.clear(draftKey)
    onSend({ ...outgoing, text: outgoing.text.trim() })
      .then(() => field.current?.focus())
      .catch((failure: unknown) => {
        drafts.update(
          draftKey,
          (meanwhile) => restoreDraft(outgoing, meanwhile),
        )
        setError(errorMessage(failure))
      })
      .finally(() => setSending(false))
  }

  return (
    <ComposerZone
      session={pill}
      error={error}
      above={draft.reply && (
        <QuoteStrip
          sender={senderName(directory, draft.reply, sessions)}
          text={draft.reply.text}
          onClear={() =>
            drafts.update(draftKey, (held) => ({ ...held, reply: null }))}
        />
      )}
      tray={
        <PendingFiles
          files={draft.files}
          onRemove={(id) => {
            setError(null)
            drafts.update(draftKey, (held) => ({
              ...held,
              files: held.files.filter((file) => file.id !== id),
            }))
          }}
        />
      }
      onDropFiles={attach}
    >
      <input
        ref={picker}
        type='file'
        multiple
        hidden
        onChange={(event) => {
          attach([...(event.target.files ?? [])])
          event.target.value = ''
        }}
      />
      <ComposerButton
        icon='paperclip'
        label='Attach files'
        onClick={() => picker.current!.click()}
      />
      <textarea
        ref={field}
        rows={1}
        aria-label={placeholder}
        aria-keyshortcuts='Shift+Enter'
        placeholder={placeholder}
        value={draft.text}
        onChange={(event) => {
          const text = event.target.value
          setError(null)
          drafts.update(draftKey, (held) => ({ ...held, text }))
        }}
        onPaste={(event) => {
          const pasted = [...event.clipboardData.files]
          if (pasted.length === 0) return
          event.preventDefault()
          attach(pasted)
        }}
        onKeyDown={(event) => {
          if (
            isComposerSendKey({
              key: event.key,
              shiftKey: event.shiftKey,
              isComposing: event.nativeEvent.isComposing,
            })
          ) {
            event.preventDefault()
            send()
          }
        }}
      />
      {dictate && (
        <ComposerButton
          icon={dictation.phase === 'recording' ? 'stop' : 'mic'}
          label={dictation.phase === 'recording'
            ? 'Stop and transcribe'
            : dictation.phase === 'off'
            ? 'Dictate'
            : 'Transcribing…'}
          pressed={dictation.phase === 'recording'}
          busy={dictation.phase === 'starting' ||
            dictation.phase === 'transcribing'}
          onClick={() => {
            setError(null)
            dictation.toggle()
          }}
        />
      )}
      <SendButton
        disabled={!canSend}
        label='Send (Shift+Enter)'
        onClick={send}
      />
    </ComposerZone>
  )
}
