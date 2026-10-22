import type { MouseEvent, ReactNode } from 'react'

// The sidebar kit, from the mock's src/kit: white cards of rows. Anything with
// an href is a real link, so a modified click still opens a tab; a plain click
// goes through onNavigate.

export type StatusTone = 'working' | 'not' | 'trouble'

export interface LinkProps {
  href?: string
  current?: boolean
  onNavigate?: (href: string) => void
}

function linkAttributes({ href, current, onNavigate }: LinkProps) {
  if (href == null) return {}
  return {
    href,
    'aria-current': current ? 'page' as const : undefined,
    onClick: (event: MouseEvent) => {
      if (
        onNavigate == null || event.button !== 0 || event.metaKey ||
        event.ctrlKey || event.shiftKey || event.altKey
      ) {
        return
      }
      event.preventDefault()
      onNavigate(href)
    },
  }
}

// A count of what is unread; nothing at zero.
export function Count(
  { value, tone = 'dark' }: { value: number; tone?: 'dark' | 'grey' },
) {
  if (value <= 0) return null
  return (
    <span className='wui-count' data-tone={tone}>
      {value > 99 ? '99+' : value}
    </span>
  )
}

// A round photo (any element) at a size.
export function AvatarSlot(
  { size, children }: { size: number; children: ReactNode },
) {
  return (
    <span className='wui-avatar' style={{ width: size, height: size }}>
      {children}
    </span>
  )
}

// Rounded square holding a glyph or an initial: leads a row with no photo.
export function LeadIcon({ children }: { children: ReactNode }) {
  return <span className='wui-lead-icon'>{children}</span>
}

export interface Status {
  tone: StatusTone
  label: string
}

export function Row({
  lead,
  label,
  caption,
  status,
  trail,
  className,
  ...link
}: LinkProps & {
  lead?: ReactNode
  label: ReactNode
  caption?: ReactNode
  // A status line in place of the caption: a dot and its word, toned.
  status?: Status | null
  trail?: ReactNode
  className?: string
}) {
  const Tag = link.href == null ? 'div' : 'a'
  return (
    <Tag
      className={className ? `wui-row ${className}` : 'wui-row'}
      {...linkAttributes(link)}
    >
      {lead}
      <div className='wui-row-text'>
        <div className='wui-row-label'>{label}</div>
        {status
          ? (
            <div className='wui-row-caption wui-status' data-tone={status.tone}>
              {status.label}
            </div>
          )
          : caption && <div className='wui-row-caption'>{caption}</div>}
      </div>
      {trail != null && <span className='wui-row-trail'>{trail}</span>}
    </Tag>
  )
}

// Children hanging off a parent row on a tree line.
export function Tree({ children }: { children: ReactNode }) {
  return <div className='wui-tree'>{children}</div>
}

// One white card; with a title, a list of divided rows.
export function ListCard(
  { title, accessory, children }: {
    title?: string
    accessory?: ReactNode
    children: ReactNode
  },
) {
  return (
    <section className='wui-card wui-list'>
      {title && (
        <header className='wui-card-head'>
          <span>{title}</span>
          {accessory}
        </header>
      )}
      {children}
    </section>
  )
}

// The agent card: photo, name, status line, unread pill. The whole card links.
export function AgentCard({
  lead,
  name,
  status,
  caption,
  count,
  ...link
}: LinkProps & {
  lead: ReactNode
  name: string
  status?: Status | null
  caption?: ReactNode
  count?: ReactNode
}) {
  const Tag = link.href == null ? 'section' : 'a'
  return (
    <Tag className='wui-card wui-agent' {...linkAttributes(link)}>
      {lead}
      <div className='wui-agent-text'>
        <div className='wui-agent-name'>{name}</div>
        {status
          ? (
            <div className='wui-status' data-tone={status.tone}>
              {status.label}
            </div>
          )
          : caption && <div className='wui-row-caption'>{caption}</div>}
      </div>
      {count}
    </Tag>
  )
}

// One entity with live children: its head row links, and each child row
// links on its own. A current row is an inset fill, not the whole card.
export function EntityCard({
  lead,
  title,
  caption,
  status,
  trail,
  children,
  ...link
}: LinkProps & {
  lead: ReactNode
  title: string
  caption?: ReactNode
  status?: Status | null
  trail?: ReactNode
  children: ReactNode
}) {
  return (
    <section className='wui-card wui-entity'>
      <Row
        className='wui-entity-head'
        lead={lead}
        label={title}
        caption={caption}
        status={status}
        trail={trail}
        {...link}
      />
      <Tree>{children}</Tree>
    </section>
  )
}
