import {
  destinationPath,
  parseSpaceURL,
  type SpaceDestination,
  spaceDestination,
  spaceHost,
} from './space-url.ts'
import { sharedGroup } from './groups.ts'

export type SessionView = 'transcript' | 'context'

export const screens = {
  enroll: '/_/enroll',
  login: '/_/login',
  sessions: '/_/sessions',
  settings: '/_/settings',
  system: '/_/system',
  templates: '/_/templates',
} as const

// The history state New session navigates with: the roster may not list the
// new id yet.
export interface CreatedSession {
  created: string
}

// The SPA runs on the bare host for every group: a place in another group is
// its path with `?group=`, and shared's has none.
export function withGroup(href: string, group: string): string {
  if (group === sharedGroup) return href
  const cut = href.indexOf('#')
  const [base, fragment] = cut === -1
    ? [href, '']
    : [href.slice(0, cut), href.slice(cut)]
  const joiner = base.includes('?') ? '&' : '?'
  return `${base}${joiner}group=${encodeURIComponent(group)}${fragment}`
}

export function placeGroup(search: string): string {
  return new URLSearchParams(search).get('group') ?? sharedGroup
}

// The query a place's content keeps: its group is the SPA's alone.
export function withoutGroup(search: string): string {
  const params = new URLSearchParams(search)
  params.delete('group')
  const rest = params.toString()
  return rest === '' ? '' : `?${rest}`
}

export function placeHref(
  destination: SpaceDestination,
  group: string,
): string {
  return withGroup(destinationPath(destination), group)
}

export function sessionHref(
  id: string,
  group: string,
  view?: SessionView,
): string {
  const path = destinationPath({ kind: 'session', id })
  return withGroup(view == null ? path : `${path}?view=${view}`, group)
}

export function conversationHref(id: string, group: string): string {
  return placeHref({ kind: 'conversation', id }, group)
}

export function fileHref(path: string, group: string): string {
  return placeHref({ kind: 'path', path }, group)
}

const localSpace = /^wuhu:\/\/([^/.]+)\.localspace(\/.*)$/i

// `wuhu://<g>.localspace/<path>` names group g's path; a hostless one is in
// the group it is read from.
export function groupAddress(
  address: string,
  group: string,
): { group: string; path: string } {
  const match = localSpace.exec(address)
  return match == null
    ? { group, path: address }
    : { group: match[1].toLowerCase(), path: match[2] }
}

const systemOrigin = 'wuhu://system'

// `wuhu://system/…` names a read-only file built into the server. Only the
// read tool serves it, so the SPA opens it on its own screen, never as a space
// path.
export function isSystemAddress(path: string): boolean {
  return path.startsWith(`${systemOrigin}/`)
}

// Where a session-context entry opens: a space path, or a system address.
export function entryHref(path: string, group: string): string {
  if (isSystemAddress(path)) {
    const rest = path.slice(systemOrigin.length)
    return screens.system + destinationPath({ kind: 'path', path: rest })
  }
  const address = groupAddress(path, group)
  return fileHref(address.path, address.group)
}

export function systemAddress(pathname: string): string | null {
  if (!pathname.startsWith(`${screens.system}/`)) return null
  const destination = spaceDestination(pathname.slice(screens.system.length))
  return destination?.kind === 'path' && destination.path !== '/'
    ? systemOrigin + destination.path
    : null
}

export function sessionView(search: string): SessionView | null {
  const view = new URLSearchParams(search).get('view')
  return view === 'transcript' || view === 'context' ? view : null
}

const externalHref = /^([a-z][a-z0-9+.-]*:|\/\/)/i

// The group a link's host names: an https link's own host is shared and one
// label under it that label's group; a wuhu link names `<g>.localspace`.
function hostGroup(
  linkHost: string,
  host: string,
  wuhu: boolean,
): string | null {
  if (!wuhu && linkHost === host) return sharedGroup
  const parent = wuhu ? 'localspace' : host
  if (!linkHost.endsWith(`.${parent}`)) return null
  const label = linkHost.slice(0, -parent.length - 1)
  return label.includes('.') ? null : label
}

// A link in a document stays in the SPA when it names this space: a plain,
// relative or hostless `wuhu:/` path in the document's own group, or a link
// into one of this host's groups.
export function spaceLink(
  href: string,
  group: string,
  sourcePath?: string,
  origin: string = globalThis.location?.origin ?? '',
): string | null {
  const hostless = /^wuhu:\/(?!\/)/i.test(href)
  if (hostless || /^(https|wuhu):\/\//i.test(href)) {
    const host = spaceHost(origin)
    const url = host == null ? null : parseSpaceURL(href, host)
    if (url == null) return null
    const linked = hostless
      ? group
      : hostGroup(url.host, host!, /^wuhu:/i.test(href))
    if (linked == null) return null
    const query = url.query == null ? '' : `?${url.query}`
    const fragment = url.fragment == null ? '' : `#${url.fragment}`
    return withGroup(
      `${destinationPath(url.destination)}${query}${fragment}`,
      linked,
    )
  }
  if (externalHref.test(href) || href.startsWith('#')) return null
  const cut = href.search(/[?#]/)
  const path = cut === -1 ? href : href.slice(0, cut)
  const suffix = cut === -1 ? '' : href.slice(cut)
  if (path === '') return null
  const baseDir = sourcePath == null
    ? ''
    : sourcePath.slice(0, sourcePath.lastIndexOf('/'))
  const raw = path.startsWith('/') ? path : `${baseDir}/${path}`
  const segments: string[] = []
  for (const segment of raw.split('/')) {
    if (segment === '' || segment === '.') continue
    if (segment === '..') segments.pop()
    else segments.push(segment)
  }
  return withGroup(`/${segments.join('/')}${suffix}`, group)
}
