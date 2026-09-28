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
  }
}
