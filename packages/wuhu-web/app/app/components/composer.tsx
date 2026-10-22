import { useEffect, useRef, useState } from 'react'
import { ComposerRow, Glass, GlassButton, Glyph } from '@wuhu/ui'
import { isComposerSendKey, sendKeyLabel, useSendKey } from '~/lib/composer'
import { type Drafts, restoreDraft, withDictation } from '~/lib/drafts'
import { useDictation } from '~/lib/use-dictation'
import { useDraft } from '~/lib/use-drafts'
import { errorMessage } from '~/sdk/errors'

const fieldSizing = globalThis.CSS?.supports('field-sizing', 'content') ??
  false

// The composer: a glass field that grows with its text, the mic where the
// space can transcribe, and the solid send.
export function Composer({
  drafts,
  draftKey,
  placeholder,
  dictate,
  onSend,
}: {
  drafts: Drafts
  draftKey: string
  placeholder: string
  dictate: boolean
  onSend: (text: string) => Promise<unknown>
}) {
  const text = useDraft(drafts, draftKey)
  const [error, setError] = useState<string | null>(null)
  const [sending, setSending] = useState(false)
  const field = useRef<HTMLTextAreaElement>(null)
  const sendKey = useSendKey()
  const dictation = useDictation(
    (spoken) =>
      drafts.set(draftKey, withDictation(drafts.get(draftKey), spoken)),
    setError,
  )

  // The field grows with its text (`field-sizing: content`); a browser
  // without it (Safari) is fitted here, again when the width changes.
  const fit = () => {
    const element = field.current!
    element.style.height = '0px'
    element.style.height = `${element.scrollHeight}px`
  }
  useEffect(() => {
    if (!fieldSizing) fit()
  }, [text])
  useEffect(() => {
    if (fieldSizing) return
    const observer = new ResizeObserver(fit)
    observer.observe(field.current!)
    return () => observer.disconnect()
  }, [])

  const canSend = !sending && text.trim() !== ''

  // The draft leaves the field when it is sent, so whatever is written during
  // the post is kept, and a failure puts the draft back in front.
  const send = () => {
    if (!canSend) return
    const outgoing = drafts.take(draftKey)
    setError(null)
    setSending(true)
    onSend(outgoing.trim())
      .then(() => field.current?.focus())
      .catch((failure: unknown) => {
        drafts.set(draftKey, restoreDraft(outgoing, drafts.get(draftKey)))
        setError(errorMessage(failure))
      })
      .finally(() => setSending(false))
  }

  return (
    <>
      {error && <p className='wuhu-composer-error' role='alert'>{error}</p>}
      <ComposerRow>
        <Glass size='field' className='wuhu-composer-field'>
          <textarea
            ref={field}
            rows={1}
            aria-label={placeholder}
            aria-keyshortcuts={sendKeyLabel(sendKey)}
            placeholder={placeholder}
            value={text}
            onChange={(event) => {
              setError(null)
              drafts.set(draftKey, event.target.value)
            }}
            onKeyDown={(event) => {
              if (
                isComposerSendKey({
                  key: event.key,
                  keyCode: event.keyCode,
                  shiftKey: event.shiftKey,
                  isComposing: event.nativeEvent.isComposing,
                  sendKey,
                })
              ) {
                event.preventDefault()
                send()
              }
            }}
          />
        </Glass>
        {dictate && (
          <GlassButton
            size='field'
            aria-label={dictation.phase === 'recording'
              ? 'Stop and transcribe'
              : dictation.phase === 'off'
              ? 'Dictate'
              : 'Transcribing…'}
            aria-pressed={dictation.phase === 'recording'}
            disabled={dictation.phase === 'starting' ||
              dictation.phase === 'transcribing'}
            solid={dictation.phase === 'recording'}
            onClick={() => {
              setError(null)
              dictation.toggle()
            }}
          >
            <Glyph name='mic' w={13} h={18} />
          </GlassButton>
        )}
        <GlassButton
          size='field'
          solid
          aria-label={`Send (${sendKeyLabel(sendKey)})`}
          title={`Send (${sendKeyLabel(sendKey)})`}
          disabled={!canSend}
          onClick={send}
        >
          <Glyph name='send' w={18} h={19} />
        </GlassButton>
      </ComposerRow>
    </>
  )
}
