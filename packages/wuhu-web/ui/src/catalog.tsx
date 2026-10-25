import {
  createContext,
  type CSSProperties,
  type MouseEvent,
  type ReactNode,
  useContext,
} from 'react'
import { Icon } from './icons.tsx'
import allowance from './shared/allowance.json' with { type: 'json' }

// The widget catalog: hazel-mock's UI system demo (public/demos/system/kit.jsx
// at 1a79209) in React, drawn from a script's checked result. Class names are
// the demo's, so catalog.css is its stylesheet. A widget has no state and no
// handlers: the only input is a link (`to`), and nothing shows as selected.

export interface CatalogElement {
  $element: string
  props: Record<string, unknown>
}

export interface CatalogLinks {
  // The href a `to` opens, or null when it names nowhere.
  href(to: string): string | null
  navigate(href: string): void
}

const Links = createContext<CatalogLinks>({
  href: () => null,
  navigate: () => {},
})

type Props = Record<string, unknown>

const str = (value: unknown): string | undefined =>
  value == null ? undefined : String(value)

function useLink(to: unknown) {
  const links = useContext(Links)
  const href = typeof to === 'string' ? links.href(to) : null
  if (href == null) return null
  return {
    href,
    'data-link': '',
    onClick: (event: MouseEvent) => {
      event.stopPropagation()
      if (
        event.button !== 0 || event.metaKey || event.ctrlKey ||
        event.shiftKey || event.altKey
      ) {
        return
      }
      event.preventDefault()
      links.navigate(href)
    },
  }
}

function Glyph({ name, w = 20 }: { name: unknown; w?: number }) {
  if (typeof name !== 'string') return null
  return <Icon name={name} size={w} className='glyph' />
}

// ── Containers ─────────────────────────────────────────────────────────────
function Card(
  { size = 'wide', className = '', to, title, accessory, children }: {
    size?: 'wide' | 'square'
    className?: string
    to?: unknown
    title?: unknown
    accessory?: unknown
    children?: ReactNode
  },
) {
  const link = useLink(to)
  const head = title != null && (
    <header className='k-head'>
      <span>{str(title)}</span>
      {accessory != null && <span className='accessory'>{str(accessory)}</span>}
    </header>
  )
  const classes = `block ${size} ${className}`
  return link == null
    ? (
      <section className={classes}>
        {head}
        {children}
      </section>
    )
    : (
      <a className={classes} {...link}>
        {head}
        {children}
      </a>
    )
}

// ── Text ───────────────────────────────────────────────────────────────────
const Value = ({ value, unit }: { value: unknown; unit?: unknown }) => (
  <div className='k-value'>
    {str(value)}
    {unit != null && <small>{str(unit)}</small>}
  </div>
)
const Title = ({ children }: { children: ReactNode }) => (
  <div className='k-title'>{children}</div>
)
const Label = ({ icon, children }: { icon?: unknown; children: ReactNode }) => (
  <div className={`k-label ${icon ? 'has-icon' : ''}`}>
    {icon != null && <Glyph name={icon} w={13} />}
    {children}
  </div>
)
const Note = ({ tone, children }: { tone?: unknown; children: ReactNode }) => (
  <div className={`k-note ${str(tone) ?? ''}`}>{children}</div>
)
const Body = ({ children }: { children: ReactNode }) => (
  <p className='k-body'>{children}</p>
)

// ── Marks ──────────────────────────────────────────────────────────────────
function Orb(
  { icon, label, to }: { icon: unknown; label?: unknown; to?: unknown },
) {
  const link = useLink(to)
  const glyph = <Glyph name={icon} w={18} />
  return link == null
    ? <span className='orb' title={str(label)}>{glyph}</span>
    : <a className='orb' title={str(label)} {...link}>{glyph}</a>
}

function Button({ label, icon, primary, to }: Props) {
  const link = useLink(to)
  const className = `k-button ${(primary ?? true) ? 'primary' : ''}`
  const inside = (
    <>
      {icon != null && <Glyph name={icon} w={14} />}
      {str(label)}
    </>
  )
  return link == null
    ? <span className={className}>{inside}</span>
    : <a className={className} {...link}>{inside}</a>
}

const Chip = ({ tone, children }: { tone?: unknown; children: ReactNode }) => (
  <span className={`chip ${str(tone) ?? ''}`}>{children}</span>
)
const Tag = ({ tone, children }: { tone?: unknown; children: ReactNode }) => (
  <span className={`tag ${str(tone) ?? ''}`}>{children}</span>
)
function Avatar({ src, size, status }: Props) {
  const side = typeof size === 'number' ? size : 30
  return (
    <span className='avatar' style={{ width: side, height: side }}>
      {typeof src === 'string' && <img src={src} alt='' />}
      {status != null && <i className={`dot ${str(status)}`} />}
    </span>
  )
}
const LeadIcon = ({ name, tone }: Props) => (
  <span className={`lead-icon ${str(tone) ?? ''}`}>
    <Glyph name={name} w={16} />
  </span>
)

// ── Rows ───────────────────────────────────────────────────────────────────
function Row(p: Props & { className?: string }) {
  const link = useLink(p.to)
  const head = p.lead != null ? part(p.lead) : p.icon != null &&
    (p.tint
      ? <Glyph name={p.icon} w={20} />
      : <LeadIcon name={p.icon} tone={p.tone} />)
  const className = `row ${p.tint ? `tinted ${str(p.tint)}` : ''} ${
    p.className ?? ''
  }`
  const inside = (
    <>
      {head}
      <div className='row-text'>
        <div className='row-label'>{part(p.label)}</div>
        {p.caption != null && (
          <div className='row-caption'>
            {p.dot != null && <i className={`dot ${str(p.dot)}`} />}
            {part(p.caption)}
          </div>
        )}
      </div>
      {p.trail != null && <span className='row-trail'>{part(p.trail)}</span>}
    </>
  )
  return link == null
    ? <div className={className}>{inside}</div>
    : <a className={className} {...link}>{inside}</a>
}
const Tree = ({ children }: { children: ReactNode }) => (
  <div className='k-tree'>{children}</div>
)

// ── Data marks ─────────────────────────────────────────────────────────────
function smooth(pts: number[][]): string {
  let d = `M${pts[0]![0]} ${pts[0]![1]}`
  for (let i = 0; i < pts.length - 1; i++) {
    const p0 = pts[i - 1] ?? pts[i]!,
      p1 = pts[i]!,
      p2 = pts[i + 1]!,
      p3 = pts[i + 2] ?? p2
    const c1 = [p1[0]! + (p2[0]! - p0[0]!) / 6, p1[1]! + (p2[1]! - p0[1]!) / 6]
    const c2 = [p2[0]! - (p3[0]! - p1[0]!) / 6, p2[1]! - (p3[1]! - p1[1]!) / 6]
    d += ` C${c1.map((n) => n.toFixed(1)).join(' ')} ${
      c2.map((n) => n.toFixed(1)).join(' ')
    } ${p2[0]!.toFixed(1)} ${p2[1]!.toFixed(1)}`
  }
  return d
}

function Chart(
  { points, w = 135, h = 68, tone = 'data', dot = 4.5, line }: {
    points: number[]
    w?: number
    h?: number
    tone?: string
    dot?: number
    line?: number
  },
) {
  if (points.length === 0) return null
  const top = 1, floor = line ?? h - dot - 1
  const min = Math.min(...points), max = Math.max(...points)
  const pts = points.map((y, i) => [
    (i / Math.max(points.length - 1, 1)) * w,
    top + (1 - (y - min) / (max - min || 1)) * (floor - top),
  ])
  const d = smooth(pts)
  const [ex, ey] = pts[pts.length - 1]!
  return (
    <svg
      className={`k-chart ${tone}`}
      width={w + dot + 1.5}
      height={h}
      viewBox={`0 0 ${w + dot + 1.5} ${h}`}
    >
      <path d={`${d} L${ex} ${h} L0 ${h}Z`} className='area' />
      <path d={d} className='line' />
      <circle cx={ex} cy={ey} r={dot} className='dot' />
    </svg>
  )
}

function Meter(
  { value, max, shape = 'bar', size = 40 }: {
    value: number
    max: number
    shape?: string
    size?: number
  },
) {
  if (shape === 'ring') {
    const sw = size / 6.5,
      r = (size - sw) / 2,
      c = 2 * Math.PI * r,
      f = Math.min(value / max, 1)
    return (
      <svg
        className='k-ring'
        width={size}
        height={size}
        viewBox={`0 0 ${size} ${size}`}
      >
        <circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          className='track'
          strokeWidth={sw}
        />
        <circle
          cx={size / 2}
          cy={size / 2}
          r={r}
          className='fill'
          strokeWidth={sw}
          strokeDasharray={`${c * f} ${c}`}
          transform={`rotate(-90 ${size / 2} ${size / 2})`}
        />
      </svg>
    )
  }
  return (
    <div className='k-bar'>
      {shape === 'ticks'
        ? Array.from(
          { length: Math.max(0, Math.min(max, 60)) },
          (_, i) => <i key={i} className={i < value ? 'on' : ''} />,
        )
        : (
          <i
            className='on'
            style={{ flex: 'none', width: `${(value / max) * 100}%` }}
          />
        )}
    </div>
  )
}

interface Band {
  label?: string
  days?: number
  tint?: string
}

function Series(
  { days, bands, axis }: { days: number[]; bands?: Band[]; axis?: string[] },
) {
  return (
    <div className='k-series'>
      <div className='k-bars'>
        {days.map((n, i) => (
          <i
            key={i}
            className={n ? 'hit' : ''}
            style={{ height: `${n ? 12 + n * 9 : 8}px` }}
          />
        ))}
      </div>
      {bands && (
        <div className='k-bands'>
          {bands.map((b, i) => (
            <div key={i} className={b.tint} style={{ flex: b.days }}>
              {b.label}
            </div>
          ))}
        </div>
      )}
      {axis && (
        <div className='k-axis'>
          {axis.map((a, i) => <span key={i}>{a}</span>)}
        </div>
      )}
    </div>
  )
}

function Heatmap(
  { days, offset = 0, today }: {
    days: (number | null)[]
    offset?: number
    today?: number
  },
) {
  const cells = [...Array<null>(offset).fill(null), ...days]
  return (
    <div className='k-heatmap'>
      {['M', 'T', 'W', 'T', 'F', 'S', 'S'].map((d, i) => <b key={i}>{d}</b>)}
      {cells.map((v, i) => {
        const day = i - offset + 1
        return (
          <i
            key={i}
            className={v == null
              ? 'blank'
              : `l${v} ${day === today ? 'today' : ''}`}
          >
            {v == null ? '' : day}
          </i>
        )
      })}
    </div>
  )
}

// ── Templates ──────────────────────────────────────────────────────────────
const agentStatus: Record<string, string> = {
  working: 'working',
  'not-working': 'not working',
  idle: 'idle',
}

const numbers = (value: unknown): number[] =>
  Array.isArray(value) ? value.map(Number) : []

type Size = 'wide' | 'small'

function Subject(p: Props) {
  const actions = Array.isArray(p.actions) ? p.actions as Props[] : []
  return (
    <Card size='square' to={p.to} className='t-subject'>
      <Avatar src={p.avatar} size={35} />
      <Title>{str(p.name)}</Title>
      <Label>{str(p.caption)}</Label>
      <div className='t-orbs'>
        {actions.map((a, i) => (
          <Orb key={i} icon={a.icon} label={a.label} to={a.to} />
        ))}
      </div>
    </Card>
  )
}

function Agent(p: Props) {
  const status = str(p.status)
  return (
    <Card to={p.to} className='t-agent'>
      <Avatar src={p.avatar} size={34} />
      <div className='t-agent-text'>
        <Title>{str(p.name)}</Title>
        {status && (
          <div className={`t-agent-status ${status}`}>
            <Label>
              <i className='dot' />
              {agentStatus[status] ?? status}
            </Label>
          </div>
        )}
      </div>
      {p.unread ? <Chip tone='dark'>{str(p.unread)}</Chip> : null}
    </Card>
  )
}

function FigureText(p: Props) {
  return (
    <>
      <Value value={p.value} unit={p.unit} />
      {p.label != null && <Label>{str(p.label)}</Label>}
      {p.note != null && <Note tone={p.tone}>{str(p.note)}</Note>}
    </>
  )
}

function Figure(p: Props & { size: Size }) {
  const meter = p.meter as { value: number; max: number } | undefined
  if (p.size === 'wide') {
    return (
      <Card to={p.to} className='t-figure wide'>
        {p.icon != null && <Orb icon={p.icon} label={p.label} />}
        <div className='t-figure-text'>
          <FigureText {...p} />
        </div>
        {p.chart != null && <Chart points={numbers(p.chart)} line={49} />}
        {meter != null && (
          <Meter shape='ring' size={38} value={meter.value} max={meter.max} />
        )}
      </Card>
    )
  }
  return (
    <Card size='square' to={p.to} className='t-figure'>
      <div className='t-figure-top'>
        {p.icon != null ? <Orb icon={p.icon} label={p.label} /> : <span />}
        {p.chart != null && (
          <Chart points={numbers(p.chart)} w={64} h={32} dot={3} />
        )}
        {meter != null && (
          <Meter shape='ring' size={38} value={meter.value} max={meter.max} />
        )}
      </div>
      <FigureText {...p} />
    </Card>
  )
}

function Doc(p: Props & { size: Size }) {
  if (p.size === 'small') {
    return (
      <Card size='square' to={p.to} className='t-doc'>
        <Orb icon={p.icon ?? 'file-document'} label={p.title} />
        <Title>{str(p.title)}</Title>
        {p.caption != null && <Label>{str(p.caption)}</Label>}
      </Card>
    )
  }
  const action = p.action as Props | undefined
  return (
    <Card to={p.to} className='t-doc'>
      {p.kicker != null && <Label icon={p.icon}>{str(p.kicker)}</Label>}
      <div className='t-doc-main'>
        <div>
          <Title>{str(p.title)}</Title>
          {p.caption != null && <Label>{str(p.caption)}</Label>}
        </div>
        {p.badge != null && <Chip tone='countdown'>{str(p.badge)}</Chip>}
      </div>
      {p.preview != null && <Body>{str(p.preview)}</Body>}
      {(p.meta != null || action != null) && (
        <div className='t-doc-foot'>
          {p.meta != null ? <Label>{str(p.meta)}</Label> : <span />}
          {action != null && <Button {...action} />}
        </div>
      )}
    </Card>
  )
}

function List(p: Props) {
  const rows = Array.isArray(p.rows) ? p.rows as Props[] : []
  const link = useLink(p.to)
  if (p.count == null) {
    return (
      <Card
        title={p.title}
        accessory={p.accessory}
        to={p.to}
        className='t-list'
      >
        {rows.map((r, i) => <Row key={i} {...r} />)}
      </Card>
    )
  }
  return (
    <Card className='t-list counted'>
      <Value value={p.count} />
      <Label>{str(p.label)}</Label>
      {link != null && (
        <a className='t-expand' title='Open all' {...link}>
          <Glyph name='screen-full' w={17} />
        </a>
      )}
      <div className='t-rows'>
        {rows.map((r, i) => (
          <Row key={i} tint={i % 2 ? 'green' : 'blue'} {...r} />
        ))}
      </div>
    </Card>
  )
}

function Pattern(p: Props) {
  return (
    <Card title={p.title} accessory={p.accessory} className='t-pattern'>
      {p.icon != null && <Orb icon={p.icon} label={p.label} />}
      {p.value != null && (
        <div className='t-pattern-head'>
          <Value value={p.value} unit={p.unit} />
          <Label>{str(p.label)}</Label>
        </div>
      )}
      <Series
        days={numbers(p.days)}
        bands={p.bands as Band[] | undefined}
        axis={p.axis as string[] | undefined}
      />
      {p.legend != null && (
        <div className='t-legend'>
          <Label>{str(p.legend)}</Label>
        </div>
      )}
    </Card>
  )
}

function Progress(p: Props) {
  return (
    <Card
      title={p.title}
      accessory={`${p.value} / ${p.max}`}
      to={p.to}
      className='t-progress'
    >
      <Meter
        value={Number(p.value)}
        max={Number(p.max)}
        shape={p.ticks ? 'ticks' : 'bar'}
      />
      {p.caption != null && <Label>{str(p.caption)}</Label>}
    </Card>
  )
}

function Calendar(p: Props) {
  return (
    <Card
      title={p.title}
      accessory={p.accessory}
      to={p.to}
      className='t-calendar'
    >
      <Heatmap
        offset={typeof p.offset === 'number' ? p.offset : 0}
        days={Array.isArray(p.days) ? p.days as (number | null)[] : []}
        today={typeof p.today === 'number' ? p.today : undefined}
      />
    </Card>
  )
}

function Entity(p: Props) {
  const chip = p.chip as { tone?: string; label?: string } | undefined
  const children = Array.isArray(p.children) ? p.children : []
  return (
    <Card to={p.to} className='t-entity'>
      <Row
        className='t-entity-head'
        lead={p.lead}
        label={p.title}
        caption={p.sub}
        trail={chip && <Chip tone={chip.tone}>{chip.label}</Chip>}
      />
      {(p.open ?? true) && children.length > 0 && (
        <Tree>
          {children.map((child, i) => <Part key={i} value={child} />)}
        </Tree>
      )}
    </Card>
  )
}

const partViews: Record<string, (props: Props) => ReactNode> = {
  Row,
  Tag: (p) => <Tag tone={p.tone}>{part(p.children)}</Tag>,
  Chip: (p) => <Chip tone={p.tone}>{part(p.children)}</Chip>,
  Avatar,
  LeadIcon,
  Button,
}

function isElement(value: unknown): value is CatalogElement {
  return typeof value === 'object' && value != null &&
    typeof (value as CatalogElement).$element === 'string'
}

function Part({ value }: { value: unknown }) {
  return part(value)
}

// Text, or a part of the kit, wherever a template takes one.
function part(value: unknown): ReactNode {
  if (value == null || value === false) return null
  if (Array.isArray(value)) {
    return value.map((item, i) => <Part key={i} value={item} />)
  }
  if (isElement(value)) {
    const View = partViews[value.$element]
    return View == null ? null : <View {...value.props} />
  }
  return typeof value === 'object' ? null : String(value)
}

const templateViews: Record<
  string,
  (props: Props & { size: Size }) => ReactNode
> = {
  Subject,
  Agent,
  Figure,
  Doc,
  List,
  Pattern,
  Progress,
  Calendar,
  Entity,
}

// One widget's card at its placement's size.
export function CatalogCard(
  { element, size, links }: {
    element: CatalogElement
    size: Size
    links: CatalogLinks
  },
) {
  const rule = (allowance.cards as Record<
    string,
    Record<Size, {
      props: string[]
      caps: Record<string, number>
      exclusive?: string[][]
    }>
  >)[element.$element]?.[size]
  if (rule == null) return null
  const props = Object.fromEntries(
    rule.props.map((key) => [key, element.props[key]]),
  )
  for (const [key, cap] of Object.entries(rule.caps)) {
    if (Array.isArray(props[key])) props[key] = props[key].slice(0, cap)
  }
  for (const group of rule.exclusive ?? []) {
    const kept = group.find((key) => props[key] != null)
    for (const key of group) if (key !== kept) delete props[key]
  }
  const View = templateViews[element.$element]
  if (View == null) return null
  return (
    <Links.Provider value={links}>
      <div
        className='wui-widget'
        data-size={size}
        style={Object.fromEntries(
          Object.entries(allowance.lines).map((
            [key, value],
          ) => [`--catalog-${key}-lines`, value]),
        ) as CSSProperties}
      >
        <View {...props} size={size} />
      </div>
    </Links.Provider>
  )
}

export function CatalogError({ message }: { message: string }) {
  return (
    <div className='wui-widget'>
      <pre className='s-err'>{message}</pre>
    </div>
  )
}
