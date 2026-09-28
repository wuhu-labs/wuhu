import { type FormEvent, useEffect, useRef, useState } from 'react'
import {
  ComposerZone,
  Icon,
  SendButton,
  ThreadHead,
  ThreadMessage,
} from '@wuhu/ui'
import { DocPage } from './doc.tsx'

const replies = [
  'Yes, I can see your message clearly — the new UI is delivering messages successfully.',
  'Looked at the backup notes. The --one-file-system flag is the whole story; I would move the "why restic" section above the fix so the reader meets the reason before the incantation.',
  'Done. I rewrote the summary to lead with the flag and folded the rsync comparison into one sentence under it. Want me to also drop the files table into a callout?',
  'Hey! 👋',
]

interface Turn {
  id: number
  you: string
  reply?: string
}

type Phase = 'idle' | 'thinking' | 'peek'

export function PeekPage() {
  return <DocPage />
}

export function PeekComposer() {
  const [draft, setDraft] = useState('')
  const [turns, setTurns] = useState<Turn[]>([])
  const [phase, setPhase] = useState<Phase>('idle')
  const [held, setHeld] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const last = turns.at(-1)

  const clear = () => {
    if (timer.current !== null) clearTimeout(timer.current)
    timer.current = null
  }

  const send = (event?: FormEvent) => {
    event?.preventDefault()
    const message = draft.trim()
    if (!message || phase === 'thinking') return
    clear()
    const id = turns.length
    setTurns((all) => [...all, { id, you: message }])
    setDraft('')
    setPhase('thinking')
    timer.current = setTimeout(() => {
      const reply = replies[id % replies.length]
      setTurns((all) =>
        all.map((turn) => turn.id === id ? { ...turn, reply } : turn)
      )
      setPhase('peek')
    }, 1400)
  }

  useEffect(() => {
    if (phase !== 'peek' || held) return
    const linger = setTimeout(() => setPhase('idle'), 9000)
    return () => clearTimeout(linger)
  }, [phase, held, last?.id])

  useEffect(() => clear, [])

  // ?auto plays one turn on load so a screenshot or a first visit shows the
  // peek without typing.
  useEffect(() => {
    if (!new URLSearchParams(globalThis.location.search).has('auto')) return
    const start = setTimeout(() => {
      const message = 'i am just testing some new ui, can you see this message'
      setTurns([{ id: 0, you: message }])
      setPhase('thinking')
      timer.current = setTimeout(() => {
        setTurns([{ id: 0, you: message, reply: replies[0] }])
        setPhase('peek')
      }, 1400)
    }, 300)
    return () => clearTimeout(start)
  }, [])

  const above = phase === 'idle' ? null : (
    <div
      className='lab-peek'
      data-phase={phase}
      onMouseEnter={() => setHeld(true)}
      onMouseLeave={() => setHeld(false)}
    >
      {phase === 'thinking'
        ? (
          <div className='lab-peek-thinking'>
            <span className='lab-peek-avatar'>AS</span>
            <span>ASC is thinking</span>
            <span className='lab-peek-dots' aria-hidden='true'>
              <i />
              <i />
              <i />
            </span>
          </div>
        )
        : (
          <div className='lab-peek-card' data-held={held}>
            <span className='lab-peek-avatar'>AS</span>
            <div className='lab-peek-body'>
              <div className='lab-peek-head'>
                <strong>ASC</strong>
                <span>replied to “{last?.you}”</span>
              </div>
              <p>{last?.reply}</p>
            </div>
            <div className='lab-peek-actions'>
              <button type='button' title='Open session'>
                <Icon name='chevronUp' />
              </button>
              <button
                type='button'
                title='Dismiss'
                onClick={() => setPhase('idle')}
              >
                ×
              </button>
            </div>
            <span className='lab-peek-fuse' aria-hidden='true' />
          </div>
        )}
    </div>
  )

  return (
    <ComposerZone
      session={{ label: 'ASC', dot: 'mint' }}
      above={above}
      thread={
        <>
          <ThreadHead title='ASC · task' meta={`${turns.length} turns`} />
          {turns.length === 0 && (
            <ThreadMessage avatar='AS' author='ASC'>
              Nothing yet. Send something from the document and the reply will
              peek in above the composer.
            </ThreadMessage>
          )}
          {turns.map((turn) => (
            <div key={turn.id}>
              <ThreadMessage avatar='AM' author='Alex Morgan' you>
                {turn.you}
              </ThreadMessage>
              {turn.reply && (
                <ThreadMessage avatar='AS' author='ASC'>
                  {turn.reply}
                </ThreadMessage>
              )}
            </div>
          ))}
        </>
      }
    >
      <form className='lab-peek-form' onSubmit={send}>
        <input
          aria-label='Direct message'
          placeholder='Direct message (appends to the transcript)…'
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
      </form>
      <SendButton
        disabled={!draft.trim() || phase === 'thinking'}
        onClick={() => send()}
      />
    </ComposerZone>
  )
}
