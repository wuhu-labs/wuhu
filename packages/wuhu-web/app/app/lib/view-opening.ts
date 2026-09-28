import type { DataView } from './contract.gen.ts'

const renderedViews = new Set(['kanban', 'list', 'wall', 'map'])

type ViewOpening =
  | { state: 'text'; content: string; notice: string }
  | { state: 'renderable'; doc: DataView }

export function viewOpening(content: string): ViewOpening {
  let doc: DataView
  try {
    doc = JSON.parse(content) as DataView
  } catch {
    return {
      state: 'text',
      content,
      notice: 'Not valid JSON — showing the raw view doc.',
    }
  }
  if (!renderedViews.has(doc.view)) {
    return {
      state: 'text',
      content,
      notice: `Unsupported view kind: ${doc.view} — showing the raw view doc.`,
    }
  }
  return { state: 'renderable', doc }
}
