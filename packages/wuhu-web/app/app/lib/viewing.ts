import type { NodeView } from './node-view.ts'

// The server's `Viewing` rules (wuhu-core SpaceCore MessageViewing.swift and
// SpaceFS SpacePath.swift), mirrored so a send omits what it would refuse;
// lib/viewing.vectors.json is the fixture both clients and the server test.
const maxBytes = 1024
const refused = /[<>&"'\p{White_Space}\p{Cc}]/u
const group = /^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/

// Controls and whitespace are refused across the whole spelling, so a
// component only has its own rules left.
function validComponent(component: string): boolean {
  if (component === '' || component === '.' || component === '..') return false
  return !/[@%#?\p{Cf}]/u.test(component)
}

// `path` in `group` as a send names it, `wuhu://<group>.localspace/<path>`,
// or null when the server would refuse it or it names no doc or page: the
// root is a listing.
export function viewingSpelling(groupId: string, path: string): string | null {
  if (!group.test(groupId) || !path.startsWith('/')) return null
  const normalized = path.normalize('NFC')
  if (!normalized.slice(1).split('/').every(validComponent)) return null
  const spelling = `wuhu://${groupId}.localspace${normalized}`
  if (new TextEncoder().encode(spelling).length > maxBytes) return null
  if (refused.test(spelling)) return null
  return spelling
}

// What a node page has on screen (lib/use-shown-node.ts): the path it was
// opened at in its group, and the path it resolved to there (the root's
// homepage, or the root's own listing), with the view it shows.
export interface ShownPage {
  group: string
  requested: string
  path: string
  view: NodeView
}

// The doc or page a send names: what the node page actually displays, never
// one still loading or failed to open, and never the root's own listing.
export function viewingOf(shown: ShownPage | null): string | null {
  if (shown === null) return null
  if (shown.view.state === 'loading' || shown.view.state === 'error') {
    return null
  }
  return viewingSpelling(shown.group, shown.path)
}
