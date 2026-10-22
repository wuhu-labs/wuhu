import iconNames from './iconamoon-names.json' with { type: 'json' }

// A script's result, checked before anything draws it: a sidebar is a
// <Sidebar> of PageCards and Widgets, a widget is one catalog template made
// of the kit's parts. Anything else is a sentence for its error card.

export interface Element {
  $element: string
  props: Record<string, unknown>
}

export interface PageEntry {
  page?: string
  title?: string
  status?: string
  badge?: number
  avatar?: string
}

export interface PageCardSpec extends PageEntry {
  children: PageEntry[]
}

export type WidgetSize = 'wide' | 'small'

export const widgetSizes: readonly WidgetSize[] = ['wide', 'small']

export type SidebarItem =
  | { kind: 'page'; card: PageCardSpec }
  | { kind: 'widget'; src: string; size: WidgetSize }

export interface SidebarTree {
  name: string
  icon: string | null
  home: string | null
  items: SidebarItem[]
}

export const templates = [
  'Subject',
  'Agent',
  'Figure',
  'Doc',
  'List',
  'Pattern',
  'Progress',
  'Calendar',
  'Entity',
] as const

export type TemplateName = typeof templates[number]

const parts = new Set(['Row', 'Tag', 'Chip', 'Avatar', 'LeadIcon', 'Button'])

export class TreeError extends Error {}

const icons = new Set<string>(iconNames)

export function knownIcon(name: string): boolean {
  return icons.has(name)
}

function isElement(value: unknown): value is Element {
  return typeof value === 'object' && value != null &&
    typeof (value as Element).$element === 'string' &&
    typeof (value as Element).props === 'object'
}

function nonblank(value: unknown): value is string {
  return typeof value === 'string' && value.trim() !== ''
}

function optional(
  props: Record<string, unknown>,
  name: string,
  type: 'string' | 'number',
  where: string,
) {
  const value = props[name]
  if (value != null && typeof value !== type) {
    throw new TreeError(`${where}: ${name} must be a ${type}`)
  }
}

// A function anywhere in a result arrives as { $function: key }.
function refuseFunctions(value: unknown, where: string) {
  if (Array.isArray(value)) {
    for (const item of value) refuseFunctions(item, where)
    return
  }
  if (typeof value !== 'object' || value == null) return
  if ('$function' in value) {
    throw new TreeError(
      `${where}: ${
        String((value as { $function: unknown }).$function)
      } is a function; widgets have no handlers, only links (to)`,
    )
  }
  for (const item of Object.values(value)) refuseFunctions(item, where)
}

function pageEntry(value: unknown, where: string): PageEntry {
  if (typeof value !== 'object' || value == null || Array.isArray(value)) {
    throw new TreeError(`${where}: each child is { page, title?, … }`)
  }
  const props = value as Record<string, unknown>
  for (const name of ['page', 'title', 'status', 'avatar']) {
    optional(props, name, 'string', where)
  }
  optional(props, 'badge', 'number', where)
  if (!nonblank(props.page) && !nonblank(props.title)) {
    throw new TreeError(`${where}: needs a page or a title`)
  }
  const entry: PageEntry = {}
  if (props.page != null) entry.page = props.page as string
  if (props.title != null) entry.title = props.title as string
  if (props.status != null) entry.status = props.status as string
  if (props.badge != null) entry.badge = props.badge as number
  if (props.avatar != null) entry.avatar = props.avatar as string
  return entry
}

export function sidebarTree(value: unknown): SidebarTree {
  refuseFunctions(value, 'Sidebar')
  if (!isElement(value) || value.$element !== 'Sidebar') {
    throw new TreeError('the default export must return one <Sidebar>')
  }
  const { name, icon, home, children } = value.props
  if (!nonblank(name)) throw new TreeError('<Sidebar> needs a name')
  optional(value.props, 'icon', 'string', '<Sidebar>')
  optional(value.props, 'home', 'string', '<Sidebar>')
  const items = (Array.isArray(children) ? children : []).map(
    (child, index): SidebarItem => {
      const where = `child ${index + 1}`
      if (!isElement(child)) {
        throw new TreeError(
          `${where}: a Sidebar holds only PageCard and Widget`,
        )
      }
      if (child.$element === 'PageCard') {
        const entry = pageEntry(child.props, `${where} <PageCard>`)
        const rows = child.props.children ?? []
        if (!Array.isArray(rows)) {
          throw new TreeError(`${where} <PageCard>: children is an array`)
        }
        return {
          kind: 'page',
          card: {
            ...entry,
            children: rows.map((row, at) =>
              pageEntry(row, `${where} <PageCard> row ${at + 1}`)
            ),
          },
        }
      }
      if (child.$element === 'Widget') {
        const { src, size = 'wide' } = child.props
        if (!nonblank(src) || !src.startsWith('/') || !src.endsWith('.jsx')) {
          throw new TreeError(
            `${where} <Widget>: src is the widget file's path, /.widgets/<name>.widget.jsx`,
          )
        }
        if (!widgetSizes.includes(size as WidgetSize)) {
          throw new TreeError(`${where} <Widget>: size is wide or small`)
        }
        return { kind: 'widget', src, size: size as WidgetSize }
      }
      throw new TreeError(
        `${where}: <${child.$element}> cannot sit in a Sidebar; only PageCard and Widget can`,
      )
    },
  )
  return {
    name,
    icon: (icon as string | undefined) ?? null,
    home: (home as string | undefined) ?? null,
    items,
  }
}

// Each template's must-haves; the rest is optional and drawn when present.
const required: Record<
  TemplateName,
  [string, 'string' | 'number' | 'array'][]
> = {
  Subject: [['name', 'string']],
  Agent: [['name', 'string']],
  Figure: [],
  Doc: [['title', 'string']],
  List: [['rows', 'array']],
  Pattern: [['days', 'array']],
  Progress: [['value', 'number'], ['max', 'number']],
  Calendar: [['days', 'array']],
  Entity: [['title', 'string']],
}

function checkParts(value: unknown, where: string) {
  if (Array.isArray(value)) {
    for (const item of value) checkParts(item, where)
    return
  }
  if (typeof value !== 'object' || value == null) return
  if (isElement(value)) {
    if (!parts.has(value.$element)) {
      throw new TreeError(
        `${where}: <${value.$element}> is not a part a template can hold`,
      )
    }
    if (value.$element === 'Button' && !nonblank(value.props.to)) {
      throw new TreeError(`${where}: a <Button> is a link and needs to`)
    }
    if (value.$element === 'LeadIcon') {
      checkIcon(value.props.name, `${where} <LeadIcon>`)
    }
    checkParts(value.props, `${where} <${value.$element}>`)
    return
  }
  if (!Array.isArray(value) && 'icon' in value) {
    checkIcon((value as { icon: unknown }).icon, where)
  }
  for (const item of Object.values(value)) checkParts(item, where)
}

function checkIcon(name: unknown, where: string) {
  if (name == null) return
  if (typeof name !== 'string' || !icons.has(name)) {
    throw new TreeError(
      `${where}: ${JSON.stringify(name)} is not an IconaMoon icon`,
    )
  }
}

// A widget's one card; `sizes` is what its module declares it can draw.
export function widgetTree(
  value: unknown,
  sizes: unknown,
  size: WidgetSize,
): Element {
  const declared = sizes === undefined ? ['wide'] : sizes
  if (
    !Array.isArray(declared) ||
    !declared.every((item) => widgetSizes.includes(item))
  ) {
    throw new TreeError('export const sizes lists wide and/or small')
  }
  if (!declared.includes(size)) {
    throw new TreeError(`it draws ${declared.join(' and ')}, not ${size}`)
  }
  refuseFunctions(value, 'widget')
  if (Array.isArray(value)) {
    throw new TreeError('a widget returns exactly one card, not a list')
  }
  if (!isElement(value)) {
    throw new TreeError('the default export must return one catalog card')
  }
  const name = value.$element
  if (!(templates as readonly string[]).includes(name)) {
    throw new TreeError(
      `<${name}> is not a catalog card (${templates.join(', ')})`,
    )
  }
  for (const [prop, type] of required[name as TemplateName]) {
    const given = value.props[prop]
    const ok = type === 'array'
      ? Array.isArray(given)
      : type === 'number'
      ? typeof given === 'number'
      : typeof given === 'string'
    if (!ok) throw new TreeError(`<${name}> needs ${prop} (${type})`)
  }
  for (const prop of ['to', 'title', 'caption', 'label', 'icon']) {
    optional(value.props, prop, 'string', `<${name}>`)
  }
  checkParts(value.props, `<${name}>`)
  return value
}
