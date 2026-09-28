import type { MouseEvent, ReactNode } from 'react'
import { useChrome } from './app-shell.tsx'
import { Icon } from './icons.tsx'
import { type MenuAction, OverflowMenu } from './menu.tsx'

export type PillTone = 'neutral' | 'live' | 'amber' | 'rose'

export interface Crumb {
  label: string
  href?: string
}

export function Topbar({ children }: { children: ReactNode }) {
  const { compact, setMode } = useChrome()
  return (
    <header className='wui-topbar'>
      {compact && (
        <button
          type='button'
          className='wui-icon-button wui-topbar-lead'
          aria-label='Show sidebar'
          onClick={() => setMode('full')}
        >
          <Icon name='sidebar' />
        </button>
      )}
      {children}
    </header>
  )
}

export function Pill(
  { tone = 'neutral', dot, children }: {
    tone?: PillTone
    dot?: boolean
    children: ReactNode
  },
) {
  return (
    <span className='wui-pill' data-tone={tone} data-dot={dot}>
      {children}
    </span>
  )
}

export function Crumbs({ path, leaf, pill, onNavigate }: {
  path: Crumb[]
  leaf: string
  pill?: ReactNode
  onNavigate?: (href: string) => void
}) {
  return (
    <div className='wui-crumbs'>
      {path.map((crumb, index) => {
        const inner = (
          <>
            {crumb.label}
            <span className='wui-sep'>/</span>
          </>
        )
        return crumb.href && onNavigate
          ? (
            <a
              key={`${crumb.label}-${index}`}
              className='wui-crumb'
              href={crumb.href}
              onClick={(event: MouseEvent) => {
                if (
                  event.metaKey || event.ctrlKey || event.shiftKey ||
                  event.altKey
                ) return
                event.preventDefault()
                onNavigate(crumb.href!)
              }}
            >
              {inner}
            </a>
          )
          : (
            <span key={`${crumb.label}-${index}`} className='wui-crumb'>
              {inner}
            </span>
          )
      })}
      <strong title={leaf}>{leaf}</strong>
      {pill}
    </div>
  )
}

// Compact has no room for a row of glyphs, so there every action folds into
// the … menu once there is more than one thing to show.
export function TopbarActions(
  { actions, menu = [] }: { actions: MenuAction[]; menu?: MenuAction[] },
) {
  const { compact } = useChrome()
  const folded = compact && actions.length + menu.length > 1
  const glyphs = folded ? [] : actions
  const items = folded ? [...menu, ...actions] : menu
  return (
    <div className='wui-top-actions'>
      {glyphs.map((action) => (
        <button
          key={action.label}
          type='button'
          className='wui-icon-button'
          aria-label={action.label}
          title={action.label}
          onClick={action.onSelect}
        >
          <Icon name={action.icon ?? 'more'} />
        </button>
      ))}
      {items.length > 0 && <OverflowMenu actions={items} label='More' />}
    </div>
  )
}
