import type { Frontiers, LoroDoc } from 'loro-crdt/web'
import type { Node as PMNode, Schema } from '@tiptap/pm/model'
import { flatten, inlineOf } from '../wmd/binding.ts'
import { type Board, boardOf, configuredBoard, type TextRun } from './board.ts'
import { CanvasEditor, sameRuns } from './editor.ts'

// An item's text or a connector's label in the editor: one paragraph whose hard breaks are the
// text's newlines, marked as `.wmd` marks its inline text.

export function inlineNodes(
  schema: Schema,
  runs: readonly TextRun[],
): PMNode[] {
  return inlineOf(
    schema,
    runs.map(({ text, ...attributes }) => ({ insert: text, attributes })),
  )
}

export function runsOf(paragraph: PMNode): TextRun[] {
  const { text, marks } = flatten(paragraph)
  const runs: TextRun[] = []
  for (let i = 0; i < text.length; i++) {
    const code = marks.code[i] === true
    const bold = marks.bold[i] === true
    const italic = marks.italic[i] === true
    const link = marks.link[i]
    const href = typeof link === 'string' ? link : undefined
    const last = runs.at(-1)
    if (
      last !== undefined && (last.code === true) === code &&
      (last.bold === true) === bold && (last.italic === true) === italic &&
      last.link === href
    ) {
      last.text += text[i]
      continue
    }
    runs.push(
      code ? { text: text[i], code: true } : {
        text: text[i],
        ...(bold ? { bold: true } : {}),
        ...(italic ? { italic: true } : {}),
        ...(href === undefined ? {} : { link: href }),
      },
    )
  }
  return runs
}

// What an editing session writes: an item's text, or a connector's label.
export interface TextTarget {
  id: string
  label?: boolean
}

const textIn = (board: Board, target: TextTarget) =>
  target.label === true
    ? board.connectors.find((c) => c.id === target.id)?.label
    : board.items.find((item) => item.id === target.id)?.text

function write(doc: LoroDoc, target: TextTarget, runs: TextRun[]) {
  const editor = new CanvasEditor(doc)
  if (target.label === true) {
    editor.updateConnector(target.id, (c) => (c.label = runs))
  } else editor.setText(target.id, runs)
}

// What `typed` becomes once merged with everything written to the target
// since the editing began at `base`: the typing replays on a fork at the base
// and imports into a fork of now, so a concurrent edit to the same text
// stays. Null when the target is gone.
export function mergedText(
  doc: LoroDoc,
  target: TextTarget,
  base: Frontiers,
  typed: readonly TextRun[],
): TextRun[] | null {
  const past = configuredBoard(doc.forkAt(base))
  const present = configuredBoard(doc.fork())
  try {
    const from = past.oplogVersion()
    write(past, target, [...typed])
    past.commit()
    present.import(past.export({ mode: 'update', from }))
    return textIn(boardOf(present), target) ?? null
  } finally {
    past.free()
    present.free()
  }
}

// Ends an editing session that began at `base` on `original`: what was typed
// merges with the doc as it is now, never with a possibly stale rendering of
// it, and lands as one local change. False when nothing needed writing.
export function finishText(
  doc: LoroDoc,
  session: TextTarget & { base: Frontiers; original: readonly TextRun[] },
  typed: readonly TextRun[],
): boolean {
  if (sameRuns([...typed], [...session.original])) return false
  const merged = mergedText(doc, session, session.base, typed)
  if (merged === null) return false
  const now = textIn(boardOf(doc), session)
  if (now === undefined || sameRuns(now, merged)) return false
  write(doc, session, merged)
  doc.commit()
  return true
}
