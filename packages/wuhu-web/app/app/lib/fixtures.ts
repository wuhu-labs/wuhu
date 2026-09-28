import type { EntryKind, SessionStreamEvent } from './contract.gen'
import {
  type DirectState,
  foldDirect,
  initialDirectState,
} from './transcript-fold'
import type { PathMap } from './tree'

function assistant(id: string, text: string) {
  return {
    assistant: {
      _0: {
        id,
        timestamp: 0,
        content: [{ text: { text } }],
        stopReason: 'end',
        usage: { input_tokens: 10, output_tokens: 20, total_tokens: 30 },
      },
    },
  }
}

function direct(id: string, sender: string, text: string) {
  return {
    direct: {
      _0: {
        id,
        sender: { id: sender, timeZone: 'UTC' },
        timestamp: 0,
        content: { text },
      },
    },
  }
}

const largeConversation: SessionStreamEvent[] = [
  { kind: 'reset', generation: 1 },
]
for (let turn = 0; turn < 12; turn += 1) {
  largeConversation.push({
    kind: 'item',
    generation: 1,
    position: turn * 2,
    item: direct(`d${turn}`, 'morgan', `Question number ${turn + 1}?`),
  })
  largeConversation.push({
    kind: 'item',
    generation: 1,
    position: turn * 2 + 1,
    item: assistant(
      `A${turn}`,
      `Answer ${turn + 1}: here is a paragraph of reasoning.`,
    ),
  })
}

const directSequences: Record<string, SessionStreamEvent[]> = {
  empty: [],
  streaming: [
    { kind: 'reset', generation: 1 },
    {
      kind: 'item',
      generation: 1,
      position: 0,
      item: direct('d1', 'morgan', 'Summarize the design doc.'),
    },
    { kind: 'started', attemptId: 'aa11bb22cc33' },
    { kind: 'delta', attemptId: 'aa11bb22cc33', text: 'Working through it' },
    { kind: 'delta', attemptId: 'aa11bb22cc33', text: ' now — one moment…' },
  ],
  settled: [
    { kind: 'reset', generation: 1 },
    {
      kind: 'item',
      generation: 1,
      position: 0,
      item: direct('d1', 'morgan', 'Summarize the design doc.'),
    },
    {
      kind: 'item',
      generation: 1,
      position: 1,
      item: assistant(
        'A1',
        'Here is the summary:\n\n- The seam owns EventSource\n- Snapshots carry liveness',
      ),
    },
  ],
  largeN: largeConversation,
}

export const directStates: Record<string, DirectState> = Object.fromEntries(
  Object.entries(directSequences).map(([name, events]) => [
    name,
    events.reduce(foldDirect, initialDirectState),
  ]),
)

function tree(entries: [string, EntryKind][]): PathMap {
  return new Map(entries)
}

const largeTree: [string, EntryKind][] = []
for (let i = 0; i < 40; i += 1) {
  largeTree.push([`/notes/entry-${String(i).padStart(2, '0')}.md`, 'file'])
}

export const treeFixtures: Record<string, PathMap> = {
  empty: new Map(),
  small: tree([
    ['/src', 'directory'],
    ['/src/main.ts', 'file'],
    ['/src/lib', 'directory'],
    ['/src/lib/observe.ts', 'file'],
    ['/readme.md', 'file'],
    ['/data.table', 'table'],
  ]),
  large: tree([['/notes', 'directory'], ...largeTree]),
}
