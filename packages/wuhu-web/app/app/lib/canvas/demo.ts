import { LoroDoc, LoroMap, LoroText, type LoroTreeNode } from 'loro-crdt/web'
import { configuredDoc } from '~/lib/wmd/loro.ts'
import { type CanvasColor, colors, type ItemKind } from './board.ts'

// A generated board for the canvas lab: sections of 15 items in a square
// grid, every kind, CJK and Latin text with marks, and a connector chain in
// each section plus one between neighbouring sections. Same seed, same doc.

const latin = [
  'Ship canvas **v1**',
  'Draft the API and *review* it with the server side',
  'Connectors follow their shapes',
  'Zoom from 10% to 800%, sharp all the way',
  'Text that does not fit shrinks, then clips — this one is deliberately long enough to need it in a small box',
  'Sync over the live channel',
  'Cull to the viewport',
]
const cjk = [
  '画布第一版',
  '连接线跟随形状移动',
  '放大缩小时文字保持清晰',
  '把**重要**的事写在便签上',
  '同步、合并、*离线*编辑以后再做',
  '日本語のテキストも表示する',
]
const kinds: ItemKind[] = [
  'sticky',
  'sticky',
  'rect',
  'ellipse',
  'diamond',
  'text',
  'sticky',
  'file',
]
const files = ['/designs/roadmap.md', '/notes/standup.wmd', '/pages/demo.html']

function random(seed: number): () => number {
  let state = seed >>> 0
  return () => {
    state = (state + 0x6d2b79f5) >>> 0
    let t = state
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function setText(meta: LoroMap, source: string) {
  const text = meta.setContainer('text', new LoroText())
  const marks: { start: number; end: number; key: string }[] = []
  let plain = ''
  for (const part of source.split(/(\*\*[^*]+\*\*|\*[^*]+\*)/)) {
    const bold = part.startsWith('**')
    const italic = !bold && part.startsWith('*')
    const body = bold ? part.slice(2, -2) : italic ? part.slice(1, -1) : part
    if (bold || italic) {
      marks.push({
        start: plain.length,
        end: plain.length + body.length,
        key: bold ? 'bold' : 'italic',
      })
    }
    plain += body
  }
  text.insert(0, plain)
  for (const { start, end, key } of marks) text.mark({ start, end }, key, true)
}

export function demoDoc(count: number, seed = 538): LoroDoc {
  const doc = configuredDoc(new LoroDoc())
  const tree = doc.getTree('tree')
  tree.enableFractionalIndex(0)
  const connectors = doc.getMap('connectors')
  const next = random(seed)
  const pick = <T>(values: readonly T[]): T =>
    values[Math.floor(next() * values.length)]
  let serial = 0
  const newId = () => (serial++).toString(36).padStart(6, '0')
  const place = (
    node: LoroTreeNode,
    kind: ItemKind,
    [x, y, w, h]: number[],
    color?: CanvasColor,
  ): string => {
    const id = newId()
    const meta = node.data
    meta.set('id', id)
    meta.set('kind', kind)
    meta.set('x', x)
    meta.set('y', y)
    meta.set('w', w)
    meta.set('h', h)
    if (color !== undefined) meta.set('color', color)
    return id
  }
  const connect = (
    from: string,
    to: string,
    style: 'straight' | 'elbow',
    label?: string,
  ) => {
    const connector = connectors.setContainer(newId(), new LoroMap())
    connector.set('from', from)
    connector.set('to', to)
    connector.set('style', style)
    if (next() < 0.1) connector.set('arrow', 'both')
    if (label !== undefined) setText(connector, label)
  }

  const perSection = 16
  const sectionCount = Math.ceil(count / perSection)
  const columns = Math.ceil(Math.sqrt(sectionCount * 1.4))
  let placed = 0
  let previousRow: string[] = []
  let row: string[] = []
  for (let s = 0; s < sectionCount && placed < count; s++) {
    const column = s % columns
    if (column === 0) {
      previousRow = row
      row = []
    }
    const section = tree.createNode()
    const sectionId = place(
      section,
      'section',
      [column * 1000, Math.floor(s / columns) * 860, 900, 780],
      pick(colors),
    )
    setText(section.data, `${pick(['Sprint', 'Track', '小组'])} ${s + 1}`)
    placed++
    if (column > 0) connect(row[column - 1], sectionId, 'straight')
    if (previousRow[column] !== undefined) {
      connect(previousRow[column], sectionId, 'elbow')
    }
    row.push(sectionId)
    let previous: string | undefined
    for (let i = 0; i < perSection - 1 && placed < count; i++) {
      const kind = kinds[(s + i) % kinds.length]
      const x = 40 + (i % 4) * 215
      const y = 60 + Math.floor(i / 4) * 180
      const node = section.createNode()
      const frame = kind === 'text' ? [x, y + 40, 180, 60] : [x, y, 180, 150]
      const color = kind === 'text' || kind === 'file'
        ? undefined
        : pick(colors)
      const id = place(node, kind, frame, color)
      if (kind === 'file') node.data.set('path', pick(files))
      else setText(node.data, next() < 0.4 ? pick(cjk) : pick(latin))
      placed++
      if (previous !== undefined && next() < 0.6) {
        connect(
          previous,
          id,
          next() < 0.5 ? 'elbow' : 'straight',
          next() < 0.2 ? pick(['next', 'then', '依赖']) : undefined,
        )
      }
      previous = id
    }
  }
  doc.commit()
  return doc
}
