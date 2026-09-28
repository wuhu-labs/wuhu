import type { QueryOutput } from './contract.gen.ts'
import { sharedGroup } from './groups.ts'
import { groupAddress, placeHref } from './links.ts'
import { spaceDestination } from './space-url.ts'
import type { PathMap } from './tree.ts'

export const everything = 'everything'

// Every view lives in one group: its Everything, or one of its sidebar files.
export interface SidebarView {
  group: string
  sidebar: string
}

export const sharedEverything: SidebarView = {
  group: sharedGroup,
  sidebar: everything,
}

export function sameView(a: SidebarView, b: SidebarView): boolean {
  return a.group === b.group && a.sidebar === b.sidebar
}

export interface SidebarSection {
  id: string
  title: string
  sql: string
}

export type SidebarFile =
  & { path: string; title: string }
  & ({ sections: SidebarSection[] } | { failure: string })

export interface SidebarNode {
  id: string
  parent: string | null
  title: string
  destination: string
  order: number | null
}

const directory = '/.sidebars/'

export function sidebarPaths(paths: PathMap): string[] {
  return [...paths]
    .filter(([path, kind]) =>
      kind !== 'directory' && path.startsWith(directory) &&
      path.endsWith('.json') && !path.slice(directory.length).includes('/')
    )
    .map(([path]) => path)
    .sort()
}

export function touchesSidebars(path: string): boolean {
  return path === directory.slice(0, -1) || path.startsWith(directory)
}

export function sidebarName(path: string): string {
  return path.slice(path.lastIndexOf('/') + 1).replace(/\.json$/, '')
}

function nonblank(value: unknown): value is string {
  return typeof value === 'string' && value.trim() !== ''
}

// Any shape the decoder cannot read, a JSON null included, throws and lands
// in the one failure sentence.
function decode(
  content: string,
): { title: string; sections: SidebarSection[] } {
  const value = JSON.parse(content)
  const sections: SidebarSection[] = value.sections.map(
    ({ id, title, sql }: SidebarSection) => ({ id, title, sql }),
  )
  const valid = nonblank(value.title) &&
    (value.icon == null || typeof value.icon === 'string') &&
    sections.every(({ id, title, sql }) =>
      typeof id === 'string' && id !== '' && typeof title === 'string' &&
      title !== '' && nonblank(sql)
    ) &&
    new Set(sections.map(({ id }) => id)).size === sections.length
  if (!valid) throw new Error('invalid sidebar definition')
  return { title: value.title, sections }
}

export function sidebarFile(path: string, content: string): SidebarFile {
  try {
    return { path, ...decode(content) }
  } catch {
    return {
      path,
      title: sidebarName(path),
      failure: `${sidebarName(path)} is not a readable sidebar definition.`,
    }
  }
}

export function validDestination(address: string): boolean {
  if (address === 'chat') return true
  const value = groupAddress(address, sharedGroup).path
  if (value.length < 2 || value.endsWith('/') || /[@%#?]/.test(value)) {
    return false
  }
  const destination = spaceDestination(value)
  return destination != null &&
    (destination.kind !== 'path' || !value.startsWith('/_/'))
}

// A section is a hierarchy or it is refused whole: one bad row would otherwise
// draw a link to nowhere or hang a branch off a parent that is not there.
export function sidebarNodes(output: QueryOutput): SidebarNode[] {
  const { columns } = output
  const column = (name: string) => columns.indexOf(name)
  const [id, parent, title, destination] = [
    'id',
    'parent_id',
    'title',
    'destination',
  ].map(column)
  if (
    new Set(columns).size !== columns.length ||
    [id, parent, title, destination].includes(-1)
  ) {
    throw new Error(
      'The section query needs unique id, parent_id, title, and destination columns.',
    )
  }
  const order = column('sort_order') === -1
    ? column('order')
    : column('sort_order')
  const nodes = output.rows.map((row): SidebarNode => {
    const rowId = row[id]
    const rowTitle = row[title]
    const rowDestination = row[destination]
    const rowParent = row[parent]
    if (
      typeof rowId !== 'string' || rowId === '' || !nonblank(rowTitle) ||
      typeof rowDestination !== 'string' || !validDestination(rowDestination)
    ) {
      throw new Error(
        'Each row needs an ID, title, and an absolute document, chat, or agent destination.',
      )
    }
    if (!(rowParent === null || (typeof rowParent === 'string' && rowParent))) {
      throw new Error('Parent IDs must be nonempty strings or null.')
    }
    const rowOrder = order === -1 ? null : row[order]
    if (
      rowOrder !== null &&
      (typeof rowOrder !== 'number' || !Number.isFinite(rowOrder))
    ) {
      throw new Error('Section ordering must be numeric or null.')
    }
    return {
      id: rowId,
      parent: rowParent,
      title: rowTitle,
      destination: rowDestination,
      order: rowOrder,
    }
  })
  const parents = new Map(nodes.map((node) => [node.id, node.parent]))
  if (parents.size !== nodes.length) {
    throw new Error('The section contains duplicate row IDs.')
  }
  if (nodes.some((node) => node.parent != null && !parents.has(node.parent))) {
    throw new Error('A section row refers to a missing parent.')
  }
  for (const node of nodes) {
    const seen = new Set<string>()
    for (let at = node.parent; at != null; at = parents.get(at) ?? null) {
      if (seen.has(at)) throw new Error('The section contains a parent cycle.')
      seen.add(at)
    }
  }
  return [...nodes].sort((a, b) =>
    (a.order ?? 0) - (b.order ?? 0) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)
  )
}

export type RowTarget =
  | { kind: 'session'; id: string; href: string }
  | { kind: 'conversation' | 'document' | 'table'; href: string }

// `chat` opens the view's first live agent and has no row without one; a
// hostless destination is in the view's group.
export function rowTarget(
  destination: string,
  firstAgent: string | null,
  group: string,
): RowTarget | null {
  if (destination === 'chat') {
    return firstAgent == null ? null : {
      kind: 'session',
      id: firstAgent,
      href: placeHref({ kind: 'session', id: firstAgent }, group),
    }
  }
  const address = groupAddress(destination, group)
  const parsed = spaceDestination(address.path)!
  const href = placeHref(parsed, address.group)
  switch (parsed.kind) {
    case 'session':
      return { kind: 'session', id: parsed.id, href }
    case 'conversation':
      return { kind: 'conversation', href }
    case 'path':
      return {
        kind: /\.(view|table)$/.test(parsed.path) ? 'table' : 'document',
        href,
      }
  }
}

// The choice is this browser's, per account and space.
function memoryKey(scope: string): string {
  return `wuhu.view/${scope}`
}

export function recallSidebar(scope: string | null): SidebarView {
  const kept = scope == null ? null : localStorage.getItem(memoryKey(scope))
  return kept == null ? sharedEverything : JSON.parse(kept)
}

export function rememberSidebar(
  scope: string | null,
  view: SidebarView,
): void {
  if (scope != null) {
    localStorage.setItem(memoryKey(scope), JSON.stringify(view))
  }
}
