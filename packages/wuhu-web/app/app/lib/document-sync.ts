import type { ReadOutput, SyncOutput } from './contract.gen.ts'

export type DocumentPhase =
  | 'clean'
  | 'dirty'
  | 'saving'
  | 'conflict'
  | 'error'

export interface DocumentState {
  base: ReadOutput
  draft: string
  phase: DocumentPhase
  remote?: ReadOutput
  error?: string
}

export function documentState(read: ReadOutput): DocumentState {
  return { base: read, draft: read.content, phase: 'clean' }
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
  if (state.draft === submitted) return documentState(remote)
  if (output.content === submitted) {
    return { base: remote, draft: state.draft, phase: 'dirty' }
  }
  return { ...state, phase: 'conflict', remote }
}

export function useRemote(state: DocumentState): DocumentState {
  return state.remote == null ? state : documentState(state.remote)
}

export function keepLocal(state: DocumentState): DocumentState {
  if (state.remote == null) return state
  return { base: state.remote, draft: state.draft, phase: 'dirty' }
}
