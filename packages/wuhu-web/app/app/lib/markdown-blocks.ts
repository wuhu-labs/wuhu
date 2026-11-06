import type {
  Blockquote,
  Nodes,
  Paragraph,
  Parent,
  PhrasingContent,
  Root,
  Text,
} from 'mdast'

const calloutTitles: Record<string, string> = {
  note: 'Note',
  tip: 'Tip',
  important: 'Important',
  warning: 'Warning',
  caution: 'Caution',
}

const calloutMarker = /^\[!([A-Za-z]+)\][ \t]*\n?/

const mentionPattern = /(^|[\s(])@([A-Za-z0-9](?:[\w.-]*\w)?)/g

function isParent(node: Nodes): node is Nodes & Parent {
  return 'children' in node
}

function walk(node: Nodes, visit: (node: Nodes, parent: Parent) => void) {
  if (!isParent(node)) return
  for (const child of [...node.children]) {
    visit(child, node)
    walk(child, visit)
  }
}

function element(
  hName: string,
  hProperties: Record<string, unknown>,
  text: string,
): Text {
  const data = {
    hName,
    hProperties,
    hChildren: [{ type: 'text', value: text }],
  }
  return { type: 'text', value: '', data: data as Text['data'] }
}

function callout(node: Blockquote) {
  const first = node.children[0]
  if (first?.type !== 'paragraph') return
  const lead = first.children[0]
  if (lead?.type !== 'text') return
  const match = calloutMarker.exec(lead.value)
  if (match == null) return
  const kind = match[1].toLowerCase()
  const title = calloutTitles[kind]
  if (title == null) return
  lead.value = lead.value.slice(match[0].length)
  if (lead.value === '') first.children.shift()
  if (first.children.length === 0) node.children.shift()
  const hProperties = {
    className: ['wuhu-callout'],
    dataKind: kind,
    dataTitle: title,
  }
  node.data = { ...node.data, hProperties } as Blockquote['data']
}

function figure(node: Paragraph) {
  const [image] = node.children
  if (node.children.length !== 1 || image.type !== 'image' || !image.alt) return
  const hProperties = { className: ['wuhu-figure'] }
  node.data = {
    ...node.data,
    hName: 'figure',
    hProperties,
  } as Paragraph['data']
  node.children.push(element('figcaption', {}, image.alt))
}

function mentions(node: Text, parent: Parent) {
  const parts: PhrasingContent[] = []
  let last = 0
  for (const match of node.value.matchAll(mentionPattern)) {
    const at = match.index + match[1].length
    const end = at + 1 + match[2].length
    if (at > last) {
      parts.push({ type: 'text', value: node.value.slice(last, at) })
    }
    parts.push(
      element(
        'span',
        { className: ['wuhu-mention'] },
        node.value.slice(at, end),
      ),
    )
    last = end
  }
  if (parts.length === 0) return
  if (last < node.value.length) {
    parts.push({ type: 'text', value: node.value.slice(last) })
  }
  parent.children.splice(parent.children.indexOf(node), 1, ...parts)
}

const wuhuCandidate = /wuhu:[^\s<>"'`]*/gi

const closers: Record<string, string> = { ')': '(', ']': '[', '}': '{' }

function count(text: string, character: string): number {
  return text.split(character).length - 1
}

function trimmedLink(candidate: string): string {
  let end = candidate.length
  while (end > 0) {
    const last = candidate[end - 1]
    const opener = closers[last]
    const head = candidate.slice(0, end)
    if ('.,!?;:'.includes(last)) end -= 1
    else if (opener != null && count(head, last) > count(head, opener)) {
      end -= 1
    } else break
  }
  return candidate.slice(0, end)
}

function isWuhuLink(spelling: string): boolean {
  const tail = spelling.slice('wuhu:'.length)
  if (tail.startsWith('//')) {
    return tail.slice(2).split(/[/?#]/)[0].includes('.')
  }
  const path = tail.split(/[?#]/)[0]
  if (!path.startsWith('/') || path.startsWith('//')) return false
  if (path === '/') return true
  return path.slice(1).split('/').every((raw) => {
    let segment: string
    try {
      segment = decodeURIComponent(raw)
    } catch {
      return false
    }
    return segment !== '' && segment !== '.' && segment !== '..' &&
      !/[/\\]/.test(segment) &&
      ![...segment].some((c) => c < ' ' || c === '\u007f')
  })
}

function wuhuLinks(node: Text, parent: Parent) {
  const parts: PhrasingContent[] = []
  let last = 0
  for (const match of node.value.matchAll(wuhuCandidate)) {
    const url = trimmedLink(match[0])
    if (url.length <= 'wuhu:'.length || !isWuhuLink(url)) continue
    if (match.index > last) {
      parts.push({ type: 'text', value: node.value.slice(last, match.index) })
    }
    parts.push({ type: 'link', url, children: [{ type: 'text', value: url }] })
    last = match.index + url.length
  }
  if (parts.length === 0) return
  if (last < node.value.length) {
    parts.push({ type: 'text', value: node.value.slice(last) })
  }
  parent.children.splice(parent.children.indexOf(node), 1, ...parts)
}

// A bare `wuhu:/path` or `wuhu://<group>.localspace/path` autolinks with the
// native renderer's boundaries. Code has no text nodes, and a link's own text
// and a mention (already a span, so no text left) stay as written.
function autolinkWuhu(node: Nodes) {
  if (
    !isParent(node) || node.type === 'link' || node.type === 'linkReference'
  ) {
    return
  }
  for (const child of [...node.children]) {
    if (child.type === 'text') wuhuLinks(child, node)
    else autolinkWuhu(child)
  }
}

// Callouts (`> [!NOTE]`), image-only paragraphs as captioned figures, and
// `@handle` mentions are tree rewrites, so the DOM the CSS targets exists
// without a rehype pass or raw HTML.
export function remarkBlocks() {
  return (tree: Root) => {
    walk(tree, (node, parent) => {
      if (node.type === 'blockquote') callout(node)
      else if (node.type === 'paragraph') figure(node)
      else if (node.type === 'text' && parent.type !== 'link') {
        mentions(node, parent)
      }
    })
    autolinkWuhu(tree)
  }
}
