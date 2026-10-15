export type ChromeMode = 'full' | 'focus'

// The shell's chrome as one value: the compact flag is written only by the
// media query's change event, and it moves together with the sidebar mode it
// decides, so no frame ever renders one without the other.
export interface ChromeState {
  compact: boolean
  mode: ChromeMode
  peek: boolean
}

export type ChromeEvent =
  | { kind: 'compact'; compact: boolean }
  | { kind: 'mode'; mode: ChromeMode }
  | { kind: 'peek'; peek: boolean }
  | { kind: 'escape' }
  | { kind: 'toggle' }

// Compact chrome has no room for a resident sidebar, so it opens collapsed.
export function chromeState(
  compact: boolean,
  defaultMode: ChromeMode,
): ChromeState {
  return { compact, mode: compact ? 'focus' : defaultMode, peek: false }
}

export function stepChrome(
  state: ChromeState,
  event: ChromeEvent,
): ChromeState {
  switch (event.kind) {
    // Crossing the compact threshold re-decides the sidebar: an overlay is not
    // a resting state, and a hidden sidebar on a wide screen is not one either.
    case 'compact':
      return event.compact === state.compact ? state : {
        compact: event.compact,
        mode: event.compact ? 'focus' : 'full',
        peek: false,
      }
    case 'mode':
      return event.mode === state.mode && !state.peek
        ? state
        : { ...state, mode: event.mode, peek: false }
    case 'peek':
      return event.peek === state.peek ? state : { ...state, peek: event.peek }
    case 'escape':
      return state.mode !== 'focus' && !state.peek
        ? state
        : { ...state, mode: 'full', peek: false }
    case 'toggle':
      return {
        ...state,
        mode: state.mode === 'focus' ? 'full' : 'focus',
        peek: false,
      }
  }
}
