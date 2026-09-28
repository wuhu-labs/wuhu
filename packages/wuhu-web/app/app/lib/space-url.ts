export type SpaceScheme = 'https' | 'wuhu'

export type SpaceDestination =
  | { kind: 'session'; id: string }
  | { kind: 'conversation'; id: string }
  | { kind: 'path'; path: string }

export interface SpaceURL {
  host: string
  destination: SpaceDestination
  query?: string
  fragment?: string
}

const schemes: readonly string[] = ['https', 'wuhu']

export function parseSpaceURL(
  spelling: string,
  contextHost?: string,
): SpaceURL | null {
  let rawHost: string
  let tail: string
  const separator = spelling.indexOf('://')
  if (separator >= 0) {
    if (!schemes.includes(spelling.slice(0, separator).toLowerCase())) {
      return null
    }
    const rest = spelling.slice(separator + 3)
    const authorityEnd = firstOf(rest, '/?#')
    rawHost = rest.slice(0, authorityEnd)
    tail = rest.slice(authorityEnd)
  } else {
    if (contextHost == null) return null
    const hostless = spelling.toLowerCase().startsWith('wuhu:/')
      ? spelling.slice('wuhu:'.length)
      : spelling
    if (!hostless.startsWith('/') || hostless.startsWith('//')) return null
    rawHost = contextHost
    tail = hostless
  }
  const host = normalizedHost(rawHost)
  if (host == null) return null
  let fragment: string | undefined
  const hash = tail.indexOf('#')
  if (hash >= 0) {
    fragment = tail.slice(hash + 1)
    tail = tail.slice(0, hash)
  }
  let query: string | undefined
  const mark = tail.indexOf('?')
  if (mark >= 0) {
    query = tail.slice(mark + 1)
    tail = tail.slice(0, mark)
  }
  const destination = spaceDestination(tail === '' ? '/' : tail)
  if (destination == null) return null
  const url: SpaceURL = { host, destination }
  if (query != null) url.query = query
  if (fragment != null) url.fragment = fragment
  return url
}

export function spaceHost(origin: string): string | null {
  const secured = origin.toLowerCase().startsWith('http://')
    ? `https://${origin.slice('http://'.length)}`
    : origin
  const url = parseSpaceURL(secured.endsWith('/') ? secured : `${secured}/`)
  if (
    url == null || url.destination.kind !== 'path' ||
    url.destination.path !== '/' || url.query != null || url.fragment != null
  ) {
    return null
  }
  return url.host
}

export function formatSpaceURL(url: SpaceURL, scheme: SpaceScheme): string {
  let spelling = `${scheme}://${url.host}${destinationPath(url.destination)}`
  if (url.query != null) spelling += `?${url.query}`
  if (url.fragment != null) spelling += `#${url.fragment}`
  return spelling
}

export function spaceDestination(
  percentEncodedPath: string,
): SpaceDestination | null {
  if (!percentEncodedPath.startsWith('/')) return null
  let raw = percentEncodedPath.slice(1)
  if (raw.endsWith('/')) raw = raw.slice(0, -1)
  if (raw === '') return { kind: 'path', path: '/' }
  const segments: string[] = []
  for (const encoded of raw.split('/')) {
    const segment = decodedSegment(encoded)
    if (segment == null) return null
    segments.push(segment)
  }
  if (segments.length === 3 && segments[0] === '_') {
    if (segments[1] === 'sessions') return { kind: 'session', id: segments[2] }
    if (segments[1] === 'conversations') {
      return { kind: 'conversation', id: segments[2] }
    }
  }
  return { kind: 'path', path: `/${segments.join('/')}` }
}

export function destinationPath(destination: SpaceDestination): string {
  switch (destination.kind) {
    case 'session':
      return `/_/sessions/${encodedSegment(destination.id)}`
    case 'conversation':
      return `/_/conversations/${encodedSegment(destination.id)}`
    case 'path':
      return destination.path === '/' ? '/' : destination.path.split('/')
        .filter((segment) => segment !== '')
        .map((segment) => `/${encodedSegment(segment)}`)
        .join('')
  }
}

function firstOf(value: string, characters: string): number {
  for (let index = 0; index < value.length; index++) {
    if (characters.includes(value[index])) return index
  }
  return value.length
}

function normalizedHost(raw: string): string | null {
  if (raw === '') return null
  for (const character of raw) {
    const code = character.codePointAt(0)!
    if (code <= 0x20 || code >= 0x7f || '@\\%'.includes(character)) {
      return null
    }
  }
  const authority = raw.toLowerCase()
  let hostEnd: number
  if (authority.startsWith('[')) {
    const close = authority.indexOf(']')
    if (close < 0) return null
    hostEnd = close + 1
  } else {
    const colon = authority.indexOf(':')
    hostEnd = colon < 0 ? authority.length : colon
  }
  if (hostEnd === 0) return null
  const port = authority.slice(hostEnd)
  if (port !== '' && !/^:[0-9]+$/.test(port)) return null
  const host = port === ':443' ? authority.slice(0, hostEnd) : authority
  // `wuhu://system/…` is the server's built-in files, never a space's host;
  // `system:5530` still is one.
  return host === 'system' ? null : host
}

// deno-lint-ignore no-control-regex
const forbidden = /[/\\\u0000-\u001f\u007f]/
const utf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true })

function decodedSegment(encoded: string): string | null {
  const bytes: number[] = []
  const raw = new TextEncoder().encode(encoded)
  for (let index = 0; index < raw.length; index++) {
    if (raw[index] !== 0x25) {
      bytes.push(raw[index])
      continue
    }
    const hex = String.fromCharCode(raw[index + 1] ?? 0, raw[index + 2] ?? 0)
    if (!/^[0-9a-fA-F]{2}$/.test(hex)) return null
    bytes.push(parseInt(hex, 16))
    index += 2
  }
  let segment: string
  try {
    segment = utf8.decode(new Uint8Array(bytes))
  } catch {
    return null
  }
  if (
    segment === '' || segment === '.' || segment === '..' ||
    forbidden.test(segment)
  ) {
    return null
  }
  return segment
}

function encodedSegment(segment: string): string {
  let encoded = ''
  for (const byte of new TextEncoder().encode(segment)) {
    const character = String.fromCharCode(byte)
    encoded += /[A-Za-z0-9\-._~]/.test(character)
      ? character
      : `%${byte.toString(16).toUpperCase().padStart(2, '0')}`
  }
  return encoded
}
