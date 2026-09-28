import type { CSSProperties, MouseEvent, ReactNode } from 'react'
import { useChrome } from './app-shell.tsx'
import { Icon, type IconName } from './icons.tsx'
import { ContextMenu, type MenuAction } from './menu.tsx'
import { Tooltip } from './tooltip.tsx'

export type DotTone = 'mint' | 'blue' | 'violet' | 'amber' | 'rose' | 'idle'

const dotClass: Record<DotTone, string> = {
  mint: 'wui-dot',
  blue: 'wui-dot wui-dot-blue',
  violet: 'wui-dot wui-dot-violet',
  amber: 'wui-dot wui-dot-amber',
  rose: 'wui-dot wui-dot-rose',
  idle: 'wui-dot wui-dot-idle',
}

export function dotToneClass(tone: DotTone): string {
  return dotClass[tone]
}

export function Sidebar({ children }: { children: ReactNode }) {
  return <aside className='wui-sidebar-body'>{children}</aside>
}

export function SidebarHeader(
  { brand, href, status, onNavigate }: {
    brand: string
    href?: string
    status?: ReactNode
    onNavigate?: () => void
  },
) {
  const { compact, setMode } = useChrome()
  const mark = <span className='wui-brand-mark'>{brand.slice(0, 1)}</span>
  const name = <span className='wui-brand-name'>{brand}</span>
  const dismiss = (
    <button
      type='button'
      className='wui-icon-button'
      aria-label={compact ? 'Close' : 'Hide sidebar'}
      onClick={() => setMode('focus')}
    >
      <Icon name={compact ? 'xmark' : 'sidebar'} />
    </button>
  )
  return (
    <header className='wui-sidebar-header'>
      {href
        ? (
          <a
            className='wui-brand'
            href={href}
            onClick={navigationHandler(onNavigate)}
          >
            {mark}
            {name}
          </a>
        )
        : (
          <div className='wui-brand'>
            {mark}
            {name}
          </div>
        )}
      {status}
      {compact ? dismiss : (
        <Tooltip label='Hide sidebar' kbd='⌘\'>
          {dismiss}
        </Tooltip>
      )}
    </header>
  )
}

export function SidebarActions({ children }: { children: ReactNode }) {
  return <div className='wui-sidebar-actions'>{children}</div>
}

export function PrimaryAction({ label, kbd, onClick }: {
  label: string
  kbd?: string
  onClick?: () => void
}) {
  return (
    <button
      type='button'
      className='wui-primary-action'
      title={label}
      onClick={onClick}
    >
      <Icon name='plus' />
      <span className='wui-row-label'>{label}</span>
      {kbd && <span className='wui-kbd'>{kbd}</span>}
    </button>
  )
}

export function SearchField({ label, kbd, onClick }: {
  label: string
  kbd?: string
  onClick?: () => void
}) {
  return (
    <button
      type='button'
      className='wui-search-field'
      title={label}
      onClick={onClick}
    >
      <Icon name='search' />
      <span className='wui-row-label'>{label}</span>
      {kbd && <span className='wui-kbd'>{kbd}</span>}
    </button>
  )
}

export function SidebarScroll({ children }: { children: ReactNode }) {
  return <div className='wui-sidebar-scroll'>{children}</div>
}

export function SidebarSection({ title, count, children }: {
  title: string
  count?: string
  children: ReactNode
}) {
  return (
    <>
      <div className='wui-section-head'>
        <span>{title}</span>
        {count && <span className='wui-count'>{count}</span>}
      </div>
      <div className='wui-tree'>{children}</div>
    </>
  )
}

export function SidebarNote(
  { children, tone }: { children: ReactNode; tone?: 'alert' },
) {
  return (
    <p className={tone === 'alert' ? 'wui-note wui-note-alert' : 'wui-note'}>
      {children}
    </p>
  )
}

export function Mark(
  { size = 17, unread, children }: {
    size?: number
    unread?: boolean
    children: ReactNode
  },
) {
  return (
    <span
      className='wui-mark'
      data-unread={unread || undefined}
      style={{ '--wui-mark-size': `${size}px` } as CSSProperties}
    >
      <span className='wui-mark-body'>{children}</span>
      {unread && (
        <span className='wui-mark-unread' role='img' aria-label='unread' />
      )}
    </span>
  )
}

// A modifier-click on a real href has to stay a browser navigation, so router
// handlers only take over the plain left click.
function navigationHandler(onClick: (() => void) | undefined) {
  if (!onClick) return undefined
  return (event: MouseEvent) => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
    event.preventDefault()
    onClick()
  }
}

export function SidebarRow(
  {
    label,
    icon,
    mark,
    status,
    meta,
    unread,
    href,
    active,
    quiet,
    depth,
    expanded,
    title,
    menu,
    onClick,
    onToggle,
  }: {
    label: string
    icon?: IconName
    mark?: ReactNode
    status?: { tone: DotTone; label: string }
    meta?: string
    unread?: boolean
    href?: string
    active?: boolean
    quiet?: boolean
    depth?: number
    expanded?: boolean
    title?: string
    menu?: MenuAction[]
    onClick?: () => void
    onToggle?: () => void
  },
) {
  const className = [
    'wui-row',
    active && 'wui-active',
    quiet && 'wui-quiet',
  ].filter(Boolean).join(' ')
  const style = depth ? { '--wui-row-depth': depth } as never : undefined
  const content = (
    <>
      {mark
        ? <Mark size={26} unread={unread}>{mark}</Mark>
        : icon && (
          <Mark unread={unread}>
            <Icon name={icon} />
          </Mark>
        )}
      <span className='wui-row-label'>{label}</span>
      {status && (
        <span
          className={`${dotClass[status.tone]} wui-row-status`}
          role='img'
          aria-label={status.label}
          title={status.label}
        />
      )}
      {meta && <span className='wui-row-meta'>{meta}</span>}
    </>
  )
  const element = href
    ? (
      <a
        className={className}
        style={style}
        href={href}
        title={title ?? label}
        onClick={navigationHandler(onClick)}
      >
        {content}
      </a>
    )
    : (
      <button
        type='button'
        className={className}
        style={style}
        title={title ?? label}
        onClick={onClick}
      >
        {content}
      </button>
    )
  const row = menu
    ? <ContextMenu actions={menu}>{element}</ContextMenu>
    : element
  if (!onToggle) return row
  return (
    <div className='wui-row-line'>
      {row}
      <button
        type='button'
        className='wui-disclosure'
        data-expanded={expanded}
        aria-expanded={expanded}
        aria-label={`${expanded ? 'Collapse' : 'Expand'} ${label}`}
        onClick={onToggle}
      >
        <Icon name='chevronRight' />
      </button>
    </div>
  )
}

export function SidebarFooter(
  {
    initials,
    avatar,
    name,
    detail,
    settingsLabel = 'Space settings',
    children,
    onOpen,
    onSettings,
  }: {
    initials: string
    avatar?: ReactNode
    name: string
    detail?: string
    settingsLabel?: string
    children?: ReactNode
    onOpen?: () => void
    onSettings?: () => void
  },
) {
  const identity = (
    <>
      {avatar ?? <div className='wui-avatar'>{initials}</div>}
      <div className='wui-account'>
        <strong>{name}</strong>
        {detail && <span>{detail}</span>}
      </div>
    </>
  )
  return (
    <>
      {children && <div className='wui-sidebar-extra'>{children}</div>}
      <footer className='wui-sidebar-footer'>
        {onOpen
          ? (
            <button
              type='button'
              className='wui-account-open'
              aria-label={settingsLabel}
              onClick={onOpen}
            >
              {identity}
            </button>
          )
          : identity}
        {onSettings && (
          <button
            type='button'
            className='wui-icon-button'
            aria-label={settingsLabel}
            title={settingsLabel}
            onClick={onSettings}
          >
            <Icon name='gear' />
          </button>
        )}
      </footer>
    </>
  )
}
