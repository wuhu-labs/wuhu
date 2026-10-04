export interface HistoryBounds {
  id: string
  top: number
  bottom: number
}

export interface HistoryPosition {
  top: number
  anchor: { id: string; offset: number } | null
  focus: string
}

export const initialHistoryPosition: HistoryPosition = {
  top: 0,
  anchor: null,
  focus: '',
}

export function historyPosition(
  scrollTop: number,
  viewportTop: number,
  rows: HistoryBounds[],
  focus: string,
): HistoryPosition {
  const visible = rows.find((row) => row.bottom > viewportTop)
  return {
    top: scrollTop,
    anchor: visible
      ? { id: visible.id, offset: visible.top - viewportTop }
      : null,
    focus,
  }
}

export function restoredHistoryTop(
  position: HistoryPosition,
  scrollTop: number,
  viewportTop: number,
  rows: HistoryBounds[],
): number {
  const anchor = rows.find((row) => row.id === position.anchor?.id)
  return anchor && position.anchor
    ? scrollTop + anchor.top - viewportTop - position.anchor.offset
    : position.top
}
