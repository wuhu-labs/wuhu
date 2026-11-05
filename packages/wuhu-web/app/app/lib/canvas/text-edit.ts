import type { Frontiers, LoroDoc } from 'loro-crdt/web'
import type { Node as PMNode, Schema } from '@tiptap/pm/model'
import { flatten, inlineOf } from '../wmd/binding.ts'
import { boardOf, configuredBoard, type TextRun } from './board.ts'
import { CanvasEditor, sameRuns } from './editor.ts'

// An item's text in the editor: one paragraph whose hard breaks are the
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

// What `typed` becomes once merged with everything written to the item since
// the editing began at `base`: the typing replays on a fork at the base and
// imports into a fork of now, so a concurrent edit to the same text stays.
// Null when the item is gone.
export function mergedText(
  doc: LoroDoc,
  id: string,
  base: Frontiers,
  typed: readonly TextRun[],
): TextRun[] | null {
  const past = configuredBoard(doc.forkAt(base))
  const present = configuredBoard(doc.fork())
  try {
    const from = past.oplogVersion()
    new CanvasEditor(past).setText(id, [...typed])
    past.commit()
    present.import(past.export({ mode: 'update', from }))
    return boardOf(present).items.find((item) => item.id === id)?.text ??
      null
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
  session: { id: string; base: Frontiers; original: readonly TextRun[] },
  typed: readonly TextRun[],
): boolean {
  if (sameRuns([...typed], [...session.original])) return false
  const merged = mergedText(doc, session.id, session.base, typed)
  if (merged === null) return false
  const now = boardOf(doc).items.find((item) => item.id === session.id)
  if (now === undefined || sameRuns(now.text, merged)) return false
  new CanvasEditor(doc).setText(session.id, merged)
  doc.commit()
  return true
}
