const calloutTitles: Record<string, string> = {
  note: 'Note',
  tip: 'Tip',
  important: 'Important',
  warning: 'Warning',
  caution: 'Caution',
}

const calloutMarker = /^\[!([A-Za-z]+)\][ \t]*/

const mentionPattern = /(^|[\s(])@([A-Za-z0-9](?:[\w.-]*\w)?)/g

export interface Callout {
  kind: string
  title: string
  markerLength: number
}

// Mirrors the remark rewrite in markdown-blocks.ts: the marker is the first
// thing in the quote's first paragraph, and only the five GitHub kinds count.
export function callout(firstLine: string): Callout | null {
  const match = calloutMarker.exec(firstLine)
  if (match == null) return null
  const kind = match[1].toLowerCase()
  const title = calloutTitles[kind]
  if (title == null) return null
  return { kind, title, markerLength: match[0].length }
}

export interface TextRange {
  from: number
  to: number
}

export function mentions(text: string): TextRange[] {
  const ranges: TextRange[] = []
  for (const match of text.matchAll(mentionPattern)) {
    const from = match.index + match[1].length
    ranges.push({ from, to: from + 1 + match[2].length })
  }
  return ranges
}
