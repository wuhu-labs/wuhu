import {
  createContext,
  type CSSProperties,
  type ReactNode,
  useContext,
  useEffect,
  useState,
} from 'react'
import { Glass, GlassButton } from './glass.tsx'
import { Glyph } from './icons.tsx'

// How the page sits in the window: `scroll` runs the full height under the
// floating titlebar and composer; `framed` is one white card between them that
// never scrolls itself; `immersive` paints the whole window, sidebar included.
export type PageLayout = 'scroll' | 'framed' | 'immersive'

// What the chrome covers of the page, in CSS px, the same numbers a hosted
// page receives as --wuhu-inset-*.
export interface Insets {
  top: number
  left: number
  right: number
  bottom: number
}

interface ShellState {
  // The scroll layout's scroller, the only one a page has.
  canvas: HTMLElement | null
  insets: Insets
}

const ShellContext = createContext<ShellState | null>(null)

export function useShell(): ShellState {
  const state = useContext(ShellContext)
  if (!state) throw new Error('useShell must be used inside <AppShell>')
  return state
}

// The geometry the insets name, the one source: tokens.css reads it as
// --wui-titlebar and --wui-sidebar-w.
const titlebar = 70
const sidebarWidth = 429
const zero: Insets = { top: 0, left: 0, right: 0, bottom: 0 }

interface AppStyle extends CSSProperties {
  '--wui-composer-h': string
  '--wui-titlebar': string
  '--wui-sidebar-w': string
}

export function AppShell({
  sidebarOpen,
  onToggleSidebar,
  tools,
  pinned,
  rail,
  sidebar,
  toolbar,
  composer,
  layout,
  children,
}: {
  sidebarOpen: boolean
  onToggleSidebar: () => void
  // The buttons right of the toggle; they leave with the sidebar, except the
  // first while `pinned`.
  tools: ReactNode
  pinned: boolean
  rail: ReactNode
  sidebar: ReactNode
  toolbar: ReactNode
  composer: ReactNode | null
  layout: PageLayout
  children: ReactNode
}) {
  const [canvas, setCanvas] = useState<HTMLElement | null>(null)
  const [dock, setDock] = useState<HTMLElement | null>(null)
  const [composerHeight, setComposerHeight] = useState(0)

  // The composer's live height, its bottom margin included. Insets name the
  // resting geometry: a page gets the sidebar's end state at once rather than
  // a re-layout per animation frame.
  useEffect(() => {
    if (dock === null) {
      setComposerHeight(0)
      return
    }
    const observer = new ResizeObserver(() =>
      setComposerHeight(Math.round(dock.getBoundingClientRect().height))
    )
    observer.observe(dock)
    return () => observer.disconnect()
  }, [dock])

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      // The mock's chord, ⌃⌘S.
      if (
        event.ctrlKey && event.metaKey && event.key.toLowerCase() === 's'
      ) {
        event.preventDefault()
        onToggleSidebar()
      }
    }
    globalThis.addEventListener('keydown', onKey)
    return () => globalThis.removeEventListener('keydown', onKey)
  }, [onToggleSidebar])

  const insets: Insets = layout === 'framed' ? zero : {
    top: titlebar,
    left: layout === 'immersive' && sidebarOpen ? sidebarWidth : 0,
    right: 0,
    bottom: composerHeight,
  }
  const style: AppStyle = {
    '--wui-composer-h': `${composerHeight}px`,
    '--wui-titlebar': `${titlebar}px`,
    '--wui-sidebar-w': `${sidebarWidth}px`,
  }
  return (
    <ShellContext
      value={{ canvas: layout === 'scroll' ? canvas : null, insets }}
    >
      <div className='wui-backdrop' aria-hidden='true'>
        <i />
        <i />
        <i />
        <b />
        <b />
        <b />
      </div>
      <div
        className='wui-app'
        data-sidebar={sidebarOpen ? 'open' : 'closed'}
        data-pinned={pinned || undefined}
        data-layout={layout}
        style={style}
      >
        <div
          className='wui-page'
          data-layout={layout}
          ref={layout === 'scroll' ? setCanvas : undefined}
        >
          {children}
        </div>
        <aside className='wui-sidebar'>
          <div className='wui-sidebar-body'>
            <nav className='wui-rail'>{rail}</nav>
            <div className='wui-sidebar-scroll'>
              <div className='wui-sidebar-list'>{sidebar}</div>
            </div>
          </div>
          <div className='wui-sidebar-titlebar'>
            <GlassButton
              className='wui-sidebar-toggle'
              aria-label='Toggle sidebar'
              title='Toggle sidebar (⌃⌘S)'
              aria-pressed={sidebarOpen}
              onClick={onToggleSidebar}
            >
              <Glyph name='sidebar' w={19} h={16} />
            </GlassButton>
            <div className='wui-sidebar-tools'>{tools}</div>
          </div>
        </aside>
        <header className='wui-titlebar'>{toolbar}</header>
        {composer != null && (
          <div className='wui-composer' ref={setDock}>{composer}</div>
        )}
      </div>
    </ShellContext>
  )
}

// The composer row: the field, then its round buttons, centred on the column.
export function ComposerRow({ children }: { children: ReactNode }) {
  return <div className='wui-composer-inner'>{children}</div>
}

// Back and forward, one glass pair.
export function NavButtons({
  canBack,
  canForward,
  onBack,
  onForward,
}: {
  canBack: boolean
  canForward: boolean
  onBack: () => void
  onForward: () => void
}) {
  return (
    <Glass className='wui-nav'>
      <button
        type='button'
        aria-label='Back'
        title='Back'
        disabled={!canBack}
        onClick={onBack}
      >
        <Glyph name='chevron-left' w={7.4} h={11} />
      </button>
      <span className='wui-nav-divider' />
      <button
        type='button'
        aria-label='Forward'
        title='Forward'
        disabled={!canForward}
        onClick={onForward}
      >
        <Glyph name='chevron-right' w={7.4} h={11} />
      </button>
    </Glass>
  )
}

export function TitlePill(
  { lead, children }: { lead?: ReactNode; children: ReactNode },
) {
  return (
    <Glass className={lead ? 'wui-pill wui-pill-lead' : 'wui-pill'}>
      {lead}
      <span>{children}</span>
    </Glass>
  )
}
