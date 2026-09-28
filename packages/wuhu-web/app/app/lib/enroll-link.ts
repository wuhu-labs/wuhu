export interface EnrollLink {
  token: string
  space: string
}

const spaceIdPattern = /^spc_[a-z0-9]{32}$/

// token and space travel in the fragment so they never reach a server or a
// link-preview crawler; consume stays a POST driven by the enroll page. A
// malformed space is refused up front: a bad value yields assertions the
// server rejects — but only after consume has already burned the one-time
// token.
export function parseEnrollFragment(hash: string): EnrollLink | null {
  const params = new URLSearchParams(hash.replace(/^#/, ''))
  const token = params.get('token')
  const space = params.get('space')
  if (token == null || token.length === 0) return null
  if (space == null || !spaceIdPattern.test(space)) return null
  return { token, space }
}

export function parsePastedEnrollLink(text: string): EnrollLink | null {
  const trimmed = text.trim()
  if (trimmed === '') return null
  if (trimmed.includes('://')) {
    try {
      return parseEnrollFragment(new URL(trimmed).hash)
    } catch {
      return null
    }
  }
  return parseEnrollFragment(trimmed)
}

export function enrollHash(link: EnrollLink): string {
  const params = new URLSearchParams({
    token: link.token,
    space: link.space,
  })
  return `#${params}`
}
