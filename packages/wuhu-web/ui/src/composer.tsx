import {
  type DragEvent,
  type MouseEvent,
  type ReactNode,
  useLayoutEffect,
  useRef,
  useState,
} from 'react'
import { Icon, type IconName } from './icons.tsx'
import { type DotTone, dotToneClass } from './sidebar.tsx'

export interface ComposerSession {
  label: string
  dot?: DotTone
  href?: string
  onNavigate?: () => void
}

export function ComposerZone({
  session,
  above,
  error,
  thread,
  tray,
  onDropFiles,
  children,
}: {
  session?: ComposerSession
  above?: ReactNode
  error?: ReactNode
  thread?: ReactNode
  tray?: ReactNode
  onDropFiles?: (files: File[]) => void
  children: ReactNode
}) {
  const [threadOpen, setThreadOpen] = useState(false)
  const [dropping, setDropping] = useState(false)
  const stack = useRef<HTMLDivElement>(null)

  // The page pads its bottom by the composer's height, so the last line of
  // content clears the island however tall a draft grows it.
  useLayoutEffect(() => {
    const element = stack.current!
    const root = element.closest<HTMLElement>('.wui-root')!
    const observer = new ResizeObserver(() =>
      root.style.setProperty('--wui-composer-h', `${element.offsetHeight}px`)
    )
    observer.observe(element)
    return () => {
      observer.disconnect()
      root.style.removeProperty('--wui-composer-h')
    }
  }, [])

  const carriesFiles = (event: DragEvent) =>
    onDropFiles !== undefined && event.dataTransfer.types.includes('Files')
  const dot = session && (
    <span className={dotToneClass(session.dot ?? 'mint')} />
  )
  const label = session && (
    <span className='wui-row-label'>{session.label}</span>
  )
  return (
    <>
      {thread && (
        <div className='wui-thread'>
          <section
            className='wui-thread-sheet wui-material'
            data-open={threadOpen}
            aria-label='Session thread'
          >
            {thread}
          </section>
        </div>
      )}
      <div className='wui-composer-zone'>
        <div ref={stack} className='wui-composer-stack'>
          {above}
          {error && <p className='wui-composer-error' role='alert'>{error}</p>}
          <div
            className='wui-composer wui-material'
            data-dropping={dropping}
            onDragOver={(event) => {
              if (!carriesFiles(event)) return
              event.preventDefault()
              setDropping(true)
            }}
            onDragLeave={() => setDropping(false)}
            onDrop={(event) => {
              if (!carriesFiles(event)) return
              event.preventDefault()
              setDropping(false)
              onDropFiles?.([...event.dataTransfer.files])
            }}
          >
            {tray}
            <div className='wui-composer-row'>
              {session && (thread
                ? (
                  <button
                    type='button'
                    className='wui-session-chip'
                    data-open={threadOpen}
                    title='Show thread'
                    onClick={() => setThreadOpen((open) => !open)}
                  >
                    {dot}
                    {label}
                    <span className='wui-chevron'>
                      <Icon name='chevronUp' />
                    </span>
                  </button>
                )
                : session.href
                ? (
                  <a
                    className='wui-session-chip'
                    href={session.href}
                    title={session.label}
                    onClick={(event: MouseEvent) => {
                      if (!session.onNavigate) return
                      if (
                        event.metaKey || event.ctrlKey || event.shiftKey ||
                        event.altKey
                      ) return
                      event.preventDefault()
                      session.onNavigate()
                    }}
                  >
                    {dot}
                    {label}
                  </a>
                )
                : (
                  <span className='wui-session-chip' title={session.label}>
                    {dot}
                    {label}
                  </span>
                ))}
              {children}
            </div>
          </div>
        </div>
      </div>
    </>
  )
}

export function ComposerButton({ icon, label, pressed, busy, onClick }: {
  icon: IconName
  label: string
  pressed?: boolean
  busy?: boolean
  onClick: () => void
}) {
  return (
    <button
      type='button'
      className='wui-composer-button'
      aria-label={label}
      title={label}
      aria-pressed={pressed}
      aria-busy={busy}
      disabled={busy}
      onClick={onClick}
    >
      <Icon name={icon} />
    </button>
  )
}

export function SendButton({ label = 'Send', disabled, onClick }: {
  label?: string
  disabled?: boolean
  onClick?: () => void
}) {
  return (
    <button
      type='button'
      className='wui-send-button'
      aria-label={label}
      title={label}
      disabled={disabled}
      onClick={onClick}
    >
      <Icon name='send' />
    </button>
  )
}

export function ThreadHead({ title, meta }: { title: string; meta?: string }) {
  return (
    <div className='wui-thread-head'>
      <span>{title}</span>
      <span className='wui-spacer' />
      {meta && <span>{meta}</span>}
    </div>
  )
}

export function ThreadMessage({ avatar, author, you, children }: {
  avatar: string
  author: string
  you?: boolean
  children: ReactNode
}) {
  return (
    <div className={you ? 'wui-msg wui-you' : 'wui-msg'}>
      <span className='wui-msg-avatar'>{avatar}</span>
      <div className='wui-msg-body'>
        <strong>{author}</strong>
        {children}
      </div>
    </div>
  )
}
