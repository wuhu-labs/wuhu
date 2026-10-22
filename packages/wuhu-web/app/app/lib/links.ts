import {
  destinationPath,
  parseSpaceURL,
  type SpaceDestination,
  spaceHost,
} from './space-url.ts'
import { sharedGroup } from './groups.ts'

export const screens = {
  enroll: '/_/enroll',
  login: '/_/login',
  settings: '/_/settings',
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

export function sessionHref(id: string, group: string): string {
  return placeHref({ kind: 'session', id }, group)
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

const externalHref = /^([a-z][a-z0-9+.-]*:|\/\/)/i

// The group a link's host names: an https link's own host is shared, its
// `?group=` then naming any other, and one label under it, the form older
// share links take, that label's group. Flat hosts use `<group>--<host>`;
// a wuhu link names `<g>.localspace`.
function hostGroup(
  linkHost: string,
  host: string,
  wuhu: boolean,
  contentHost: string | null | undefined,
): string | null {
  if (!wuhu && linkHost === host) return sharedGroup
  if (!wuhu && contentHost != null) {
    const [prefix, rawSuffix] = contentHost.split('{group}')
    const suffix = rawSuffix?.replace(/:443$/, '')
    if (
      suffix != null && linkHost.startsWith(prefix) && linkHost.endsWith(suffix)
    ) {
      const group = linkHost.slice(
        prefix.length,
        linkHost.length - suffix.length,
      )
      return group.includes('.') ? null : group
    }
  }
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
  { origin = globalThis.location?.origin ?? '', contentHost }: {
    origin?: string
    contentHost?: string | null
  } = {},
): string | null {
  const hostless = /^wuhu:\/(?!\/)/i.test(href)
  if (hostless || /^(https|wuhu):\/\//i.test(href)) {
    const host = spaceHost(origin)
    const url = host == null ? null : parseSpaceURL(href, host)
    if (url == null) return null
    const linked = hostless
      ? group
      : hostGroup(url.host, host!, /^wuhu:/i.test(href), contentHost)
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

// A document's name without its kind's extension; other files keep theirs.
export function fileName(path: string): string {
  const names = path.split('/').filter(Boolean)
  const last = names.at(-1)
  if (last === undefined) return '/'
  if (names.length > 1 && /^index\.[a-z]+$/i.test(last)) return names.at(-2)!
  return last.replace(/\.(md|html?|view|table)$/i, '')
}
