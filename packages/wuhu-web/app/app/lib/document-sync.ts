import type { ReadOutput, SyncOutput } from './contract.gen.ts'

export type DocumentPhase =
  | 'clean'
  | 'dirty'
  | 'saving'
  | 'conflict'
  | 'error'

// `revision` counts the times `draft` was replaced by text the editor didn't
// write. The editor owns its text and adopts `draft` only when this moves, so
// its own edits never come back down to it.
export interface DocumentState {
  base: ReadOutput
  draft: string
  phase: DocumentPhase
  revision: number
  remote?: ReadOutput
  error?: string
}

export function documentState(read: ReadOutput): DocumentState {
  return { base: read, draft: read.content, phase: 'clean', revision: 0 }
}

// A clean document at `read`. The revision moves only when the text differs
// from the draft, so a save coming back with the editor's own text leaves the
// editor's selection and undo history alone.
export function remoteDocument(
  state: DocumentState,
  read: ReadOutput,
): DocumentState {
  return {
    ...documentState(read),
    revision: read.content === state.draft
      ? state.revision
      : state.revision + 1,
  }
}

export function editDocument(
  state: DocumentState,
  draft: string,
): DocumentState {
  if (state.phase === 'conflict') return { ...state, draft }
  return {
    base: state.base,
    draft,
    phase: draft === state.base.content ? 'clean' : 'dirty',
    revision: state.revision,
  }
}

export function applySync(
  state: DocumentState,
  submitted: string,
  output: SyncOutput,
): DocumentState {
  const remote = { token: output.token, content: output.content }
  if (output.kind === 'conflict') {
    return { ...state, phase: 'conflict', remote }
  }
  if (state.draft === submitted) return remoteDocument(state, remote)
  if (output.content === submitted) {
    return {
      base: remote,
      draft: state.draft,
      phase: 'dirty',
      revision: state.revision,
    }
  }
  return { ...state, phase: 'conflict', remote }
}

export function useRemote(state: DocumentState): DocumentState {
  return state.remote == null ? state : remoteDocument(state, state.remote)
}

export function keepLocal(state: DocumentState): DocumentState {
  if (state.remote == null) return state
  return {
    base: state.remote,
    draft: state.draft,
    phase: 'dirty',
    revision: state.revision,
  }
}
