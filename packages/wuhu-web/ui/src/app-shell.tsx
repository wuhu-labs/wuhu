import {
  createContext,
  type CSSProperties,
  type ReactNode,
  useContext,
  useEffect,
  useEffectEvent,
  useReducer,
  useRef,
  useState,
} from 'react'
import { AnimatePresence, motion, MotionConfig } from 'motion/react'
import { Icon } from './icons.tsx'
import { Tooltip } from './tooltip.tsx'
import { type ChromeMode, chromeState, stepChrome } from './chrome-state.ts'

export type { ChromeMode }

interface ChromeState {
  mode: ChromeMode
  setMode: (mode: ChromeMode) => void
  compact: boolean
  // The canvas is the shell's scroll container; a route that wants to pin
  // itself to the bottom has to drive it rather than a scroller of its own.
  canvas: HTMLElement | null
}

const ChromeContext = createContext<ChromeState | null>(null)

export function useChrome(): ChromeState {
  const state = useContext(ChromeContext)
  if (!state) throw new Error('useChrome must be used inside <AppShell>')
  return state
}

// Compact opens the sidebar as a UINavigationController push — a cover from the
// left while the stage parallaxes right. Wide chrome morphs from the chip.
const coverMotion = {
  initial: { x: '-100%' },
  animate: { x: '0%' },
  exit: { x: '-100%' },
}
const fadeMotion = {
  initial: { opacity: 0 },
  animate: { opacity: 1 },
  exit: { opacity: 0 },
}

const compactQuery = '(max-width: 63.999rem)'
const edgePeekQuery = '(hover: hover) and (pointer: fine)'

function matchesNow(query: string): boolean {
  return globalThis.matchMedia?.(query).matches ?? false
}

// Calls `onChange` from the query's own change event, so whatever it sets
// renders in the same commit as the change.
function useMediaChange(query: string, onChange: (matches: boolean) => void) {
  const changed = useEffectEvent(onChange)
  useEffect(() => {
    const list = globalThis.matchMedia(query)
    const sync = () => changed(list.matches)
    sync()
    list.addEventListener('change', sync)
    return () => list.removeEventListener('change', sync)
  }, [query])
}

function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => matchesNow(query))
  useMediaChange(query, setMatches)
  return matches
}

export function AppShell({
  defaultMode = 'full',
  canvas = 'atmospheric',
  style,
  sidebar,
  topbar,
  composer,
  children,
}: {
  defaultMode?: ChromeMode
  canvas?: 'atmospheric' | 'quiet'
  style?: CSSProperties
  sidebar: ReactNode
  topbar: ReactNode
  composer?: ReactNode
  children: ReactNode
}) {
  const [chrome, send] = useReducer(
    stepChrome,
    defaultMode,
    (mode) => chromeState(matchesNow(compactQuery), mode),
  )
  const { compact, mode, peek } = chrome
  const edgePeek = useMediaQuery(edgePeekQuery)
  const [canvasEl, setCanvasEl] = useState<HTMLElement | null>(null)
  const peekTimer = useRef<ReturnType<typeof setTimeout> | null>(null)

  const cancelPeekTimer = () => {
    if (peekTimer.current !== null) {
      clearTimeout(peekTimer.current)
      peekTimer.current = null
    }
  }
  const armPeek = () => {
    if (peekTimer.current === null) {
      peekTimer.current = globalThis.setTimeout(() => {
        peekTimer.current = null
        send({ kind: 'peek', peek: true })
      }, 500)
    }
  }
  const setMode = (next: ChromeMode) => {
    cancelPeekTimer()
    send({ kind: 'mode', mode: next })
  }

  useMediaChange(compactQuery, (next) => {
    if (next !== compact) cancelPeekTimer()
    send({ kind: 'compact', compact: next })
  })

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === 'Escape') send({ kind: 'escape' })
      else if (
        event.key === '\\' && event.metaKey && !event.ctrlKey && !event.altKey
      ) {
        event.preventDefault()
        send({ kind: 'toggle' })
      } else if (event.key === '\\' && event.metaKey) {
        send({ kind: 'peek', peek: false })
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => document.removeEventListener('keydown', onKeyDown)
  }, [])

  useEffect(() => cancelPeekTimer, [])

  const rootClass = [`wui-root`, `wui-mode-${mode}`, peek && 'wui-peek']
    .filter(Boolean).join(' ')
  const showSidebar = mode === 'full' || peek

  return (
    <ChromeContext.Provider
      value={{ mode, setMode, compact, canvas: canvasEl }}
    >
      <MotionConfig
        reducedMotion='user'
        transition={{ type: 'spring', stiffness: 400, damping: 36 }}
      >
        <div className={rootClass} style={style} data-wui-compact={compact}>
          <motion.div
            className='wui-stage'
            initial={false}
            animate={{ x: compact && showSidebar ? '33%' : '0%' }}
          >
            <div
              ref={setCanvasEl}
              className={canvas === 'quiet'
                ? 'wui-canvas wui-canvas-quiet'
                : 'wui-canvas'}
            >
              <main className='wui-surface'>{children}</main>
            </div>
            {topbar}
            {composer}
          </motion.div>
          <div
            className='wui-peek-zone'
            onPointerEnter={() => {
              if (mode === 'focus' && edgePeek && !compact) armPeek()
            }}
            onPointerLeave={() => {
              cancelPeekTimer()
              send({ kind: 'peek', peek: false })
            }}
          >
            <AnimatePresence initial={false}>
              {showSidebar
                ? (
                  <motion.div
                    key='wui-sidebar'
                    className='wui-sidebar wui-material'
                    layoutId={compact ? undefined : 'wui-left-chrome'}
                    style={{ borderRadius: compact ? 0 : 22 }}
                    {...(compact ? coverMotion : fadeMotion)}
                  >
                    {sidebar}
                  </motion.div>
                )
                : compact
                ? null
                : (
                  <Tooltip
                    key='wui-sidebar-restore'
                    label='Show sidebar'
                    kbd='⌘\'
                  >
                    <motion.button
                      type='button'
                      className='wui-sidebar-restore wui-material'
                      layoutId='wui-left-chrome'
                      style={{ borderRadius: 12 }}
                      initial={{ opacity: 0 }}
                      animate={{ opacity: 1 }}
                      exit={{ opacity: 0 }}
                      aria-label='Show sidebar'
                      onClick={() => setMode('full')}
                    >
                      <motion.span
                        className='wui-restore-glyph'
                        layout
                        initial={{ opacity: 0 }}
                        animate={{
                          opacity: 1,
                          transition: { delay: 0.16, duration: 0.18 },
                        }}
                        exit={{ opacity: 0, transition: { duration: 0.06 } }}
                      >
                        <Icon name='sidebar' />
                      </motion.span>
                    </motion.button>
                  </Tooltip>
                )}
            </AnimatePresence>
          </div>
        </div>
      </MotionConfig>
    </ChromeContext.Provider>
  )
}
